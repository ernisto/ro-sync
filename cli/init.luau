local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'
local http = require '@utils/http'
local process = require '@lune/process'
local c = ctx_log.colors

local prompt = require '@cli/prompt'
local state = require '@lib/state'
local state_fs = require '@cli/state_fs'

local api = require '@lib/api'
local import = require '@lib/import'
local sync = require '@lib/sync'
local sync_logger = require '@lib/sync_logger'

-- cli
local api_key = cli.str 'api-key' or env.str 'API_KEY'
local INPUT_PATH = cli.str 'manifest' or 'cloud.yml'
local STATE_PATH = cli.str 'state' or 'cloud-state.yml'
local SCAN_CLOUD = cli.bool 'scan-roblox' -- scan whole roblox
local overwrite = cli.bool 'overwrite-roblox' -- overwrite roblox by local changes
local fresh_state = cli.bool 'ignore-conflicts' -- dont fetch roblox state for conflict checking
local scanned_cloud = false

-- login
sync_logger.print_header()

local user_session = cloud.auth.cookie.login()
local session = cloud.auth.apikey.login(api_key)
-- introspect key, show status
-- if not usable, prompt for a new key
ctx_log.str(`Logged in API Key: {c.green}"{string.sub(api_key, 1, 10)}..."`)

-- ensure resources
local function state_from_cloud(input: state.manifest?)
	if not prompt.confirm_reimport(INPUT_PATH) then return end

	local subject = prompt.prompt_subject(user_session)
	local universe_id = subject.universe.universe_id
	local resources = state.build_resources(input or state.create_input(subject.owner), state.create_state(universe_id))

	-- prompt confirm, prompt to grant product:read scope for api key
	import.await_import_products(api.build_product_api(session), universe_id, resources)

	-- prompt confirm, prompt to grant universe.place:read scope for api key
	import.await_import_places(api.build_place_api(session, user_session), universe_id, resources)

	-- prompt confirm, prompt to grant universe:read scope for api key
	import.await_import_universe(api.build_universe_api(session, user_session), universe_id, resources)

	state_fs.save_resources(resources, INPUT_PATH, STATE_PATH)
	ctx_log.str(`Saved {c.bold}{STATE_PATH}{c.reset} and {c.bold}{INPUT_PATH}`)

	scanned_cloud = true
	return resources
end
local function input_from_state(lock)
	local universe = http.request('GET', `universe/{lock.universe_id}`, function()
		return cloud.universe.get(session, { universe_id = lock.universe_id })
	end)
	local owner: state.owner = if universe.user
		then { user = tonumber(universe.user) }
		else { group = tonumber(universe.group) } :: any

	if not prompt.confirm_regen_input(INPUT_PATH, STATE_PATH) then
		return state.build_resources(state.create_input(owner), lock)
	end

	local rebuilt = state_fs.resources_from_lock(lock, owner)
	state_fs.save_resources(rebuilt, INPUT_PATH, STATE_PATH)
	ctx_log.str(`Regenerated {c.bold}{INPUT_PATH}{c.reset} from {c.bold}{STATE_PATH}`)
	return rebuilt
end
local function ensure_resources(): state.resources?
	local state_ok, state_result = pcall(state_fs.load_state, STATE_PATH)
	local input_ok, input_result = pcall(state_fs.load_input, INPUT_PATH)

	-- stylua: ignore
	return if not state_ok then state_from_cloud(input_ok and input_result or nil)
		elseif not input_ok then input_from_state(state_result)
		else state.build_resources(input_result, state_result)
end

local resources = ensure_resources()
if not resources then
	ctx_log.error 'No state loaded'
	return process.exit(1)
end

local universe = http.request('GET', `universe/{resources.lock.universe_id}`, function()
	return cloud.universe.get(session, { universe_id = resources.lock.universe_id })
end)
ctx_log.str(`Target universe: {c.bold}{universe.displayName}{c.reset} {c.dim}({resources.lock.universe_id})`)
ctx_log.str ''

local sync_opts =
	{ universe_id = resources.lock.universe_id, overwrite = overwrite, fresh_state = scanned_cloud or fresh_state }

-- reconcile
local universe_api = api.build_universe_api(session, user_session)
if resources.universe then
	local ok, err = pcall(sync.await_reconcile_universe, universe_api, resources.universe, sync_opts)
	if ok then resources.universe.lock = err end
end

local place_api = api.build_place_api(session, user_session)
for _, place in resources.places do
	local ok, err = pcall(sync.await_reconcile_place, place_api, place, sync_opts)
	if ok then place.lock = err end
end

local product_api = api.build_product_api(session)
for _, resource in resources.products do
	local ok, err = pcall(sync.await_reconcile_product, product_api, resource, sync_opts)
	if ok then resource.lock = err end
end

if SCAN_CLOUD and not scanned_cloud then state_from_cloud(resources.manifest) end

sync_logger.print_summary()
state_fs.save_resources(resources, INPUT_PATH, STATE_PATH)

-- error if fail to sync something
