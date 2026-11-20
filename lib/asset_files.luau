-- local asset files: which files a glob picks, what kind they are, and their index in the assets lock
local fs = require '@lune/fs'
local glob = require '@utils/glob'
local roblox = require '@lune/roblox'
local serde = require '@lune/serde'

-- defs
-- paths relative to the glob root, empty once every file is gone; while only staged (no id yet) a stand-in:
-- `uri` (copy in Studio's content dir) or `keyframe_root` (animations: instance names the glob root mirrors in game)
export type asset_entry = { id: number?, uri: string?, keyframe_root: { string }?, paths: { string } }
export type assets_lock = { [string]: asset_entry } -- keyed by blake3 of the source file (same keys as asphalt.lock.toml)
export type entry = { path: string, rel: string, hash: string }
export type kind = { asset_type: string, mime: string }

-- `added` holds new uploads ({ id }) or stand-ins ({ uri } / { keyframe_root }); a stand-in never replaces an id
export type added = { [string]: { id: number?, uri: string?, keyframe_root: { string }? } }

local function kind(asset_type: string, mime: string): kind
	return table.freeze { asset_type = asset_type, mime = mime }
end
local MODEL = kind('Model', 'model/x-rbxm')
local ANIMATION = kind('Animation', 'model/x-rbxm')
local KINDS: { [string]: kind } = table.freeze {
	mp3 = kind('Audio', 'audio/mpeg'),
	ogg = kind('Audio', 'audio/ogg'),
	flac = kind('Audio', 'audio/flac'),
	wav = kind('Audio', 'audio/wav'),
	png = kind('Image', 'image/png'),
	jpg = kind('Image', 'image/jpeg'),
	jpeg = kind('Image', 'image/jpeg'),
	bmp = kind('Image', 'image/bmp'),
	tga = kind('Image', 'image/tga'),
	fbx = kind('Model', 'model/fbx'),
	gltf = kind('Model', 'model/gltf+json'),
	glb = kind('Model', 'model/gltf-binary'),
	rbxm = MODEL,
	rbxmx = MODEL,
	mp4 = kind('Video', 'video/mp4'),
	mov = kind('Video', 'video/mov'),
}
local ANIMATION_CLASSES = table.freeze { KeyframeSequence = true, CurveAnimation = true }

-- kinds
local function extension(path: string): string?
	local ext = string.match(path, '%.([^./]+)$')
	return ext and string.lower(ext)
end

local function kind_of(path: string, content: string): kind
	local ext = extension(path) or ''
	local found = KINDS[ext] or error(`unsupported asset type '{ext}'`)
	if found ~= MODEL or ext == 'fbx' or ext == 'gltf' or ext == 'glb' then return found end

	local first = roblox.deserializeModel(content)[1]
	return if first and ANIMATION_CLASSES[first.ClassName] then ANIMATION else MODEL
end

-- collect
local function walk(dir: string, visit: (string) -> ())
	for _, name in fs.readDir(dir) do
		local path = if dir == '.' then name else `{dir}/{name}`
		if fs.isDir(path) then
			walk(path, visit)
		else
			visit(path)
		end
	end
end

local function collect(files: string): { entry }
	local root = glob.root_of(files) -- lock paths are relative to it
	local entries = {}
	if not fs.isDir(if root == '' then '.' else root) then return entries end

	walk(if root == '' then '.' else root, function(path)
		if not KINDS[extension(path) or ''] or not glob.is_match(files, path) then return end

		local rel = if root == '' then path else string.sub(path, #root + 2)
		table.insert(entries, { path = path, rel = rel, hash = serde.hash('blake3', fs.readFile(path)) })
	end)

	table.sort(entries, function(a, b)
		return a.path < b.path
	end)
	return entries
end

-- index
local function owner_of_path(lock: assets_lock, rel: string): string?
	for hash, entry in lock do
		if table.find(entry.paths, rel) then return hash end
	end
	return nil
end

local function is_uploaded(lock: assets_lock, hash: string): boolean
	return lock[hash] ~= nil and lock[hash].id ~= nil
end

-- keeps ids of removed files (restoring them reuses the id); a file whose new content has no id yet keeps its old one
local function build(entries: { entry }, lock: assets_lock, added: added): assets_lock
	local out: assets_lock = {}
	for hash, entry in lock do
		local staged = entry.id == nil
		out[hash] = {
			id = entry.id,
			uri = if staged then entry.uri else nil,
			keyframe_root = if staged then entry.keyframe_root else nil,
			paths = {},
		}
	end

	for hash, new in added do
		local keeps_id = out[hash] and out[hash].id and not new.id
		if not keeps_id then
			out[hash] = { id = new.id, uri = new.uri, keyframe_root = new.keyframe_root, paths = {} }
		end
	end

	for _, entry in entries do
		local hash = if out[entry.hash] then entry.hash else owner_of_path(lock, entry.rel)
		if hash then table.insert(out[hash].paths, entry.rel) end
	end
	for _, entry in out do
		table.sort(entry.paths)
	end
	return out
end

-- module
return table.freeze {
	extension = extension,
	kind_of = kind_of,
	collect = collect,
	is_uploaded = is_uploaded,
	build = build,
}
