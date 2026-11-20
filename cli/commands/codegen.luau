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

-- assets not uploaded yet point at local copies in Studio's content dir
local assets_input = manifest and manifest.assets

if assets_input then
	local assets = lock.assets or {}
	local needs_stage = false
	for _, entry in asset_files.collect(assets_input.files) do
		needs_stage = needs_stage or not asset_files.is_uploaded(assets, entry.hash)
	end

	if needs_stage then lock.assets = asset.stage(assets_input, assets, studio.content_dir()) end
end

local code = codegen.generate(lock)
if fs.isFile(OUTPUT) and fs.readFile(OUTPUT) == code then return process.exit(0) end

local dir = string.match(OUTPUT, '^(.*)/[^/]*$')
if dir and not fs.isDir(dir) then fs.writeDir(dir) end

fs.writeFile(OUTPUT, code)
ctx_log.str(`wrote {OUTPUT}`)

return process.exit(0)
