local args = require '@cli/args'
local cli = require '@utils/cli'
local ctx_log = require '@utils/ctx_log'
local fs = require '@lune/fs'
local process = require '@lune/process'

local studio = require '@utils/studio'

local auth_guidance = require '@cli/auth_guidance'
local codegen = require '@lib/codegen'
local state = require '@lib/state'
local state_fs = require '@cli/state_fs'

local asset = require '@lib/resources/asset'
local asset_files = require '@lib/asset_files'
local pass = require '@lib/resources/pass'
local place = require '@lib/resources/place'
local product = require '@lib/resources/product'

-- cli
-- `codegen [FILES...]`, positionals after the command word; extra files merge over the first like sync
local MANIFEST_PATHS = {}
for i = 2, math.huge do
	local file = cli.str(i)
	if not file then break end
	table.insert(MANIFEST_PATHS, file)
end
local STATE_PATH = cli.str 'cache' or 'cloud-state.yml'
local OUTPUT = cli.str('output', { value = 'FILE', help = 'Luau module to write (default: cloud.luau)' })
	or 'cloud.luau'
local API_KEY = args.API_KEY

cli.strict()

-- run
local lock = state_fs.load_lock(STATE_PATH)
local session = nil
if lock.extends and lock.extends.rbxstore then
	session = auth_guidance.authenticate_key(API_KEY, API_KEY ~= nil, lock.universe_id) or process.exit(1)
end
state_fs.await_load_extends(lock, session)

-- staging only shapes what codegen sees; the lock file is left as is
local function load_manifest(): state.manifest?
	if #MANIFEST_PATHS == 0 then
		if fs.isFile 'cloud.yml' then return state_fs.load_input 'cloud.yml' end

		ctx_log.warn 'no manifest (cloud.yml): only resources already in the lock are generated'
		return nil
	end

	local manifest = state_fs.load_input(MANIFEST_PATHS[1])
	for i = 2, #MANIFEST_PATHS do
		state_fs.merge_input(manifest, state_fs.load_input(MANIFEST_PATHS[i]))
	end
	return manifest
end
local manifest = load_manifest()

-- every manifest or lock entry, created or not, with the manifest input over its last cloud state
local function stage_each(res: any, inputs: { [string]: any }, locks: { [string]: any })
	local keys = table.clone(inputs)
	for key in locks do
		keys[key] = true
	end
	for key in keys do
		locks[key] = res.stage(inputs[key], locks[key])
	end
end

if manifest then
	stage_each(place, manifest.places, lock.places)
	stage_each(product, manifest.products, lock.products)
	stage_each(pass, manifest.passes, lock.passes)
end

-- files without an uploaded asset point at local copies in Studio's content dir
local function resolve_assets(input: asset.assets_input): codegen.asset_files
	local uploaded = lock.assets or {}
	local entries = asset_files.collect(input.files)
	local staged = {}
	for _, entry in entries do
		if uploaded[entry.hash] then continue end

		staged = asset.stage(input, uploaded, studio.content_dir())
		break
	end

	local out: codegen.asset_files = {}
	for _, entry in entries do
		out[entry.rel] = uploaded[entry.hash] or staged[entry.hash]
	end
	return out
end

local assets_input = manifest and manifest.assets
local code = codegen.generate(lock, assets_input and resolve_assets(assets_input))
if fs.isFile(OUTPUT) and fs.readFile(OUTPUT) == code then return process.exit(0) end

local dir = string.match(OUTPUT, '^(.*)/[^/]*$')
if dir and not fs.isDir(dir) then fs.writeDir(dir) end

fs.writeFile(OUTPUT, code)
ctx_log.str(`wrote {OUTPUT}`)

return process.exit(0)
