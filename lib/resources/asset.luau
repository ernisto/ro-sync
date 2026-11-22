local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local fs = require '@lune/fs'
local http = require '@utils/http'
local png = require '@utils/png'
local serde = require '@lune/serde'
local task = require '@lune/task'

local asset_files = require '../asset_files'
local base = require './base'
local sync_logger = require '../sync_logger'
type entry = asset_files.entry
type stand_in = asset_files.stand_in

-- defs
-- `animations`: dot path of the game folder mirroring the glob root, e.g. `ReplicatedStorage.Animations`;
-- staged animation files are registered from it (KeyframeSequenceProvider) since rbxasset:// cant load them
export type assets_input = { files: string, animations: string? }
export type asset_entry = asset_files.asset_entry
export type assets_lock = asset_files.assets_lock
export type stand_ins = { [string]: stand_in }
export type origin = { universe: number, owner: base.owner }

local DESCRIPTION = 'Uploaded by ro-sync'
local MAX_DISPLAY_NAME = 50
local MAX_POLLS = 10

-- validation
local function parse_input(t: any, label: string)
	base.req(t, 'table', label)
	base.req(t.files, 'string', `{label}.files`)
	base.opt(t.animations, 'string', `{label}.animations`)
end

local function parse_lock(t: any, label: string): assets_lock
	if t == nil then return {} end
	base.req(t, 'table', label)

	for hash, entry in t do
		base.req(hash, 'string', `{label} key`)
		base.req(entry, 'table', `{label}.{hash}`)
		base.req(entry.asset_id, 'number', `{label}.{hash}.asset_id`)
		base.opt(entry.universe, 'number', `{label}.{hash}.universe`)
		if entry.owner ~= nil then base.validate_owner(entry.owner, `{label}.{hash}.owner`) end
	end
	return t
end

-- api impl
type session = base.session

local function creator_of(owner: base.owner): { [string]: string }
	return if owner.group then { groupId = tostring(owner.group) } else { userId = tostring(owner.user) }
end

local function display_name(path: string): string
	local name = string.match(path, '[^/]*$') :: string
	return if #name > MAX_DISPLAY_NAME then string.sub(name, -MAX_DISPLAY_NAME) else name
end

local function await_operation(session: session, operation: any): number
	local delay = 1
	for attempt = 1, MAX_POLLS do
		if operation.done then
			local response = operation.response or error(`upload failed: {serde.encode('json', operation.error)}`)
			return tonumber(response.assetId) or error 'upload returned no asset id'
		end
		if attempt == MAX_POLLS then break end

		task.wait(delay)
		delay *= 2

		local id = operation.operationId or string.match(operation.path, 'operations/(.+)$')
		operation = http.call(cloud.asset.get_operation, session, { operation_id = id }, nil)
	end
	error 'upload operation polling exceeded retries'
end

local function await_upload(session: session, owner: base.owner, entry: entry): number
	local content = fs.readFile(entry.path)
	local k = asset_files.kind_of(entry.path, content)
	if k.mime == 'image/png' then content = png.bleed(content) end

	local upload: cloud.asset_upload = {
		asset = {
			assetType = k.asset_type,
			displayName = display_name(entry.path),
			description = DESCRIPTION,
			creationContext = { creator = creator_of(owner) } :: any,
		},
		content = buffer.fromstring(content),
		file_name = display_name(entry.path),
		content_type = k.mime,
	}
	return await_operation(session, http.call(cloud.asset.create, session, nil, upload))
end

-- uploads files without an asset yet; assets are a collection, so create takes and returns the whole lock
-- entries of removed files stay, restoring a file reuses its asset
local function create(session: session, origin: origin, input: assets_input, lock: assets_lock): assets_lock
	local entries = asset_files.collect(input.files)
	local out = table.clone(lock)
	local uploaded = 0

	for _, entry in entries do
		if out[entry.hash] then continue end

		sync_logger.creation(entry.path)
		local ok, id = ctx_log.try(await_upload, session, origin.owner, entry)
		if ok then
			out[entry.hash] = { asset_id = id, universe = origin.universe, owner = origin.owner }
			uploaded += 1
		end
		sync_logger.creation_result(ok)
	end

	if uploaded == 0 then sync_logger.noop(`{#entries} assets`) end
	return out
end

-- stage
local function is_animation(entry: entry): boolean
	local ext = asset_files.extension(entry.path)
	if ext ~= 'rbxm' and ext ~= 'rbxmx' then return false end

	return asset_files.kind_of(entry.path, fs.readFile(entry.path)).asset_type == 'Animation'
end

-- stand-ins for files without an uploaded id, they only resolve inside Studio:
-- animations point at their copy under `input.animations`, other files are copied into Studio's content dir
local function stage(input: assets_input, lock: assets_lock, content_dir: string): stand_ins
	local entries = asset_files.collect(input.files)
	local staged: stand_ins = {}

	local dir = `{content_dir}/ro-sync`
	if not fs.isDir(dir) then fs.writeDir(dir) end

	local keyframe_root = if input.animations then string.split(input.animations, '.') else nil

	for _, entry in entries do
		if lock[entry.hash] or staged[entry.hash] then continue end

		if is_animation(entry) then
			if keyframe_root then
				staged[entry.hash] = { keyframe_root = keyframe_root }
			else
				ctx_log.warn(`{entry.path} is an animation, set assets.animations to stage it`)
			end
			continue
		end

		local name = `{entry.hash}.{asset_files.extension(entry.path)}`
		fs.copy(entry.path, `{dir}/{name}`, true)
		staged[entry.hash] = { uri = `rbxasset://ro-sync/{name}` }
	end

	sync_logger.noop(`staged {#entries} assets`)
	return staged
end

-- module
return table.freeze {
	parse_input = parse_input,
	parse_lock = parse_lock,

	stage = stage,

	create = create,
	get = base.unsupported 'assets cant be read back from open cloud, the lock is their source',
	update = base.unsupported 'assets cant be updated: a changed file has a new hash and uploads as a new asset',
	list = base.unsupported 'assets cant be listed through open cloud, the lock is their source',
	delete = base.unsupported 'assets cant be deleted through open cloud',
}
