local fs = require '@lune/fs'
local serde = require '@lune/serde'
local state = require '@lib/state'

-- functions
local function maybe_read(path: string): buffer?
	return fs.isFile(path) and buffer.fromstring(fs.readFile(path)) or nil
end

local function resolve_icon(path: string): state.file_input?
	local content = maybe_read(path)
	return content and table.freeze { content = content, hash = serde.hash('sha256', content) }
end

local function load_resources(manifest_path: string, lock_path: string): state.resources
	local raw_manifest = maybe_read(manifest_path) or error(`couldnt load manifest '{manifest_path}'`)
	local raw_lock = maybe_read(lock_path) or error(`couldnt load lock '{lock_path}'`)

	local manifest = state.parse_manifest(raw_manifest)
	local lock = state.parse_lock(raw_lock)

	for _, product in manifest.products do
		if product.icon then product.icon_file = resolve_icon(product.icon) end
	end
	return state.build_resources(manifest, lock)
end

local function save_resources(resources: state.resources, manifest_path: string, lock_path: string)
	for _, product in resources.products do
		if product.lock then resources.lock.products[product.key] = product.lock end
	end
	fs.writeFile(lock_path, state.encode_lock(resources.lock))
	fs.writeFile(manifest_path, state.encode_manifest(resources.manifest))
end

-- module
return table.freeze {
	load_resources = load_resources,
	save_resources = save_resources,
	resolve_icon = resolve_icon,
}
