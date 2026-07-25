local fs = require '@lune/fs'
local serde = require '@lune/serde'
local state = require '@lib/state'

local MANIFEST_HEADER =
	'# yaml-language-server: $schema=https://raw.githubusercontent.com/ernisto/ro-sync/refs/heads/main/assets/manifest.schema.json\n\n'

-- functions
local function maybe_read(path: string): buffer?
	return fs.isFile(path) and buffer.fromstring(fs.readFile(path)) or nil
end

local function resolve_file(path: string): state.file_input?
	local content = maybe_read(path)
	return content and table.freeze { content = content, hash = serde.hash('sha256', content) }
end

local function files_exist(manifest_path: string): boolean
	return fs.isFile(manifest_path)
end

local function resolve_manifest_files(manifest: state.manifest)
	for _, product in manifest.products do
		if product.icon then product.icon_file = resolve_file(product.icon) end
	end
	for _, place in manifest.places do
		if place.file then place.asset_file = resolve_file(place.file) end
	end
end

local function load_input(manifest_path: string): state.manifest
	local raw_manifest = maybe_read(manifest_path) or error(`No file at {manifest_path}`)

	local manifest = state.parse_manifest(raw_manifest)
	resolve_manifest_files(manifest)
	return manifest
end

local function load_lock(lock_path: string): state.lock
	local raw_lock = maybe_read(lock_path) or error(`No file at {lock_path}`)
	return raw_lock and state.parse_lock(raw_lock)
end

local function resources_from_lock(lock: state.lock, owner: state.owner): state.resources
	local manifest: state.manifest = { owner = owner, products = {}, places = {} }

	for key, product in lock.products do
		local input: any = table.clone(product.input)
		input.icon_file, input.conflicts = nil, {}
		manifest.products[key] = input
	end
	for key, place in lock.places do
		local input: any = table.clone(place.input)
		input.asset_file, input.conflicts = nil, {}
		manifest.places[key] = input
	end
	if lock.universe then
		local input: any = table.clone(lock.universe.input)
		input.conflicts = {}
		manifest.universe = input
	end

	return state.build_resources(manifest, lock)
end

local function load_resources(manifest_path: string, lock_path: string): state.resources
	local raw_manifest = maybe_read(manifest_path) or error(`couldnt load manifest '{manifest_path}'`)
	local raw_lock = maybe_read(lock_path) or error(`couldnt load lock '{lock_path}'`)

	local manifest = state.parse_manifest(raw_manifest)
	local lock = state.parse_lock(raw_lock)

	resolve_manifest_files(manifest)
	return state.build_resources(manifest, lock)
end

local function save_resources(resources: state.resources, manifest_path: string, lock_path: string)
	for _, product in resources.products do
		if product.lock then resources.lock.products[product.key] = product.lock end
	end
	for _, place in resources.places do
		if place.lock then resources.lock.places[place.key] = place.lock end
	end
	if resources.universe then
		if resources.universe.lock then resources.lock.universe = resources.universe.lock end
	end

	fs.writeFile(lock_path, state.encode_lock(resources.lock))

	local new_yml = state.encode_manifest(resources.manifest)
	local current_yml = if fs.isFile(manifest_path)
		then serde.encode('yaml', serde.decode('yaml', fs.readFile(manifest_path)))
		else nil

	if new_yml ~= current_yml then fs.writeFile(manifest_path, MANIFEST_HEADER .. new_yml) end
end

-- module
return table.freeze {
	files_exist = files_exist,
	load_input = load_input,
	load_state = load_lock,
	resources_from_lock = resources_from_lock,
	load_resources = load_resources,
	save_resources = save_resources,
	resolve_file = resolve_file,
}
