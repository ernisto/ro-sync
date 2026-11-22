local cloud = require '@pkg/ro_cloud'
local config = require '@lib/resources/config'
local fs = require '@lune/fs'
local http = require '@utils/http'
local serde = require '@lune/serde'
local state = require '@lib/state'
local tbl = require '@utils/tbl'
local yaml = require '@utils/yaml'

local MANIFEST_HEADER =
	'# yaml-language-server: $schema=https://raw.githubusercontent.com/ernisto/ro-sync/refs/heads/main/assets/manifest.schema.json\n\n'

-- functions
local function maybe_read(path: string): buffer?
	return fs.isFile(path) and buffer.fromstring(fs.readFile(path)) or nil
end

local function resolve_file(path: string): state.input_file?
	local content = maybe_read(path)
	return content and table.freeze { content = content, hash = serde.hash('sha256', content) }
end

local function resolve_manifest_files(manifest: state.manifest)
	for _, product in manifest.products do
		if product.icon then product.icon_file = resolve_file(product.icon) end
	end
	for _, pass in manifest.passes do
		if pass.icon then pass.icon_file = resolve_file(pass.icon) end
	end
	for _, thumbnail in (manifest.thumbnails or {}) :: { any } do
		if thumbnail.file then thumbnail.image_file = resolve_file(thumbnail.file) end
	end
	if manifest.icon and manifest.icon.file then manifest.icon.image_file = resolve_file(manifest.icon.file) end
	for _, place in manifest.places do
		if place.file then place.asset_file = resolve_file(place.file) end
	end
	for key, entry in manifest.configs do
		local path = entry.value_file
		if not path then continue end

		local content = fs.isFile(path) and fs.readFile(path) or error(`configs.{key}.value_file: no file at {path}`)
		config.load_value_file(entry, content, `configs.{key}`)
	end
end

local function load_input(manifest_path: string): state.manifest
	local raw_manifest = maybe_read(manifest_path) or error(`No file at {manifest_path}`)

	local manifest = state.parse_manifest(raw_manifest)
	resolve_manifest_files(manifest)
	return manifest
end

-- extra manifests (`sync a.yml b.yml`) merge over the first, maps deeply, lists replaced
local function merge_input(base: any, extra: any)
	for k, v in extra do
		if type(v) == 'table' and type(base[k]) == 'table' and v[1] == nil then
			merge_input(base[k], v)
		else
			base[k] = v
		end
	end
end

local function load_lock(lock_path: string): state.lock
	local raw_lock = maybe_read(lock_path) or error(`No file at {lock_path}`)
	return state.parse_lock(raw_lock)
end

local function configuration_of(sub_lock: any): any
	return sub_lock and tbl.applied(sub_lock.input, { conflicts = {} })
end

-- extends
local loaded_extensions: { [state.lock]: { [string]: any } } = setmetatable({}, { __mode = 'k' }) :: any

local function store_path(lock: state.lock, store: state.rbxstore)
	return {
		universe_id = store.universe or lock.universe_id,
		data_store_id = store.store,
		scope_id = store.scope,
		entry_id = store.key,
	}
end

local function rbxstore_of(extends: state.extends): state.rbxstore
	return extends.rbxstore or error 'extends needs file or rbxstore'
end

-- nil when the entry doesnt exist yet
local function await_read_store(lock: state.lock, store: state.rbxstore, session: cloud.session?): any
	local path = store_path(lock, store)
	local ok, entry =
		pcall(http.call, cloud.data_store.get_entry, session or error 'rbxstore needs a session', path, nil)
	if ok then return entry.value end
	if string.match(tostring(entry), '^404') then return nil end
	error(entry, 0)
end

local function await_write_store(lock: state.lock, store: state.rbxstore, value: any, session: cloud.session?)
	local path = store_path(lock, store)
	local session_ = session or error 'rbxstore needs a session'
	http.call(cloud.data_store.update_entry, session_, path, { value = value }, { allowMissing = true })
end

local function await_read_extension(
	lock: state.lock,
	extends: state.extends,
	session: cloud.session?
): { [string]: any }
	if extends.file then
		local content = maybe_read(extends.file)
		return if content then serde.decode('yaml', content) else {}
	end

	return await_read_store(lock, rbxstore_of(extends), session) or {}
end

local function await_load_extends(lock: state.lock, session: cloud.session?)
	local extends = lock.extends
	if not extends then return end

	local raw = await_read_extension(lock, extends, session)
	loaded_extensions[lock] = raw
	state.merge_extended(lock, raw)
end

-- fields owned by the extending file stay as they were in the extension (other states may extend it too)
-- ponytail: last write wins, concurrent syncs can drop each other's changes; use the entry etag if that happens
local function await_save_lock(lock: state.lock, lock_path: string, session: cloud.session?)
	local extends = lock.extends
	if not extends then return fs.writeFile(lock_path, state.encode_lock(lock)) end

	local own, shared = state.split_lock(lock)
	local owned = lock.owned or {}
	local merged = {}
	local loaded: { [string]: any } = loaded_extensions[lock] or {}
	for key, value in loaded do
		if owned[key] then merged[key] = value end
	end
	for key, value in shared do
		merged[key] = value
	end

	if extends.file then
		fs.writeFile(extends.file, yaml.encode(merged))
	else
		await_write_store(lock, rbxstore_of(extends), merged, session)
	end
	fs.writeFile(lock_path, yaml.encode(own))
end

local function resources_from_lock(lock: state.lock, owner: state.owner): state.resources
	local manifest: state.manifest = state.create_input(owner)

	for key, product in lock.products do
		local input: any = table.clone(product.input)
		input.icon_file, input.conflicts = nil, {}
		manifest.products[key] = input
	end
	for key, pass in lock.passes do
		local input: any = table.clone(pass.input)
		input.icon_file, input.conflicts = nil, {}
		manifest.passes[key] = input
	end
	for key, place in lock.places do
		local input: any = table.clone(place.input)
		input.asset_file, input.conflicts = nil, {}
		input.configuration = configuration_of(place.configuration)
		manifest.places[key] = input
	end
	for key, config in lock.configs do
		local input: any = table.clone(config.input)
		input.conflicts = {}
		manifest.configs[key] = input
	end
	if lock.universe then
		local input: any = table.clone(lock.universe.input)
		input.conflicts = {}
		input.configuration = configuration_of(lock.universe.configuration)
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

local function save_manifest(manifest: state.manifest, manifest_path: string)
	local new_yml = state.encode_manifest(manifest)
	local current_yml = if fs.isFile(manifest_path)
		then yaml.encode(serde.decode('yaml', fs.readFile(manifest_path)))
		else nil

	if new_yml ~= current_yml then fs.writeFile(manifest_path, MANIFEST_HEADER .. new_yml) end
end

local function save_resources(
	resources: state.resources,
	manifest_path: string,
	lock_path: string,
	session: cloud.session?
)
	for _, product in resources.products do
		if product.lock then resources.lock.products[product.key] = product.lock end
	end
	for _, pass in resources.passes do
		if pass.lock then resources.lock.passes[pass.key] = pass.lock end
	end
	for _, thumbnail in resources.thumbnails do
		local lock = thumbnail.lock
		local file = lock and lock.input.image_file
		local hash = file and file.hash
		if lock and hash then resources.lock.thumbnails[hash] = lock end
	end
	if resources.icon and resources.icon.lock then resources.lock.icon = resources.icon.lock end
	for _, place in resources.places do
		if place.lock then resources.lock.places[place.key] = place.lock end
	end
	if resources.universe then
		if resources.universe.lock then resources.lock.universe = resources.universe.lock end
	end
	for _, config in resources.configs do
		if config.lock then resources.lock.configs[config.key] = config.lock end
	end

	await_save_lock(resources.lock, lock_path, session)
	save_manifest(resources.manifest, manifest_path)
end

-- module
return table.freeze {
	load_input = load_input,
	load_lock = load_lock,
	merge_input = merge_input,
	resources_from_lock = resources_from_lock,
	load_resources = load_resources,
	save_resources = save_resources,
	save_manifest = save_manifest,
	await_load_extends = await_load_extends,
	await_read_store = await_read_store,
	await_write_store = await_write_store,
	resolve_file = resolve_file,
}
