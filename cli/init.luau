local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'
local http = require '@utils/http'
local process = require '@lune/process'
local c = ctx_log.colors

local auth_guidance = require '@cli/auth_guidance'
local prompt = require '@cli/prompt'
local state_fs = require '@cli/state_fs'

local api = require '@lib/api'
local import = require '@lib/import'
local state = require '@lib/state'
local sync = require '@lib/sync'
local sync_logger = require '@lib/sync_logger'

-- cli
-- local COOKIE = env.str 'ROBLOX_COOKIE' -- used by auth_guidance
-- local AUTO_ACCEPT = cli.str 'yes' or cli.str 'y' -- used by prompt
local INTERACTIVE = not env.str 'CI' -- used bu prompt

local API_KEY = cli.str 'api-key' or env.str 'API_KEY'
local INPUT_PATH = cli.str 'manifest' or 'cloud.yml'
local STATE_PATH = cli.str 'state' or 'cloud-state.yml'
local SCAN_CLOUD = cli.bool 'scan-roblox' -- scan whole roblox
local overwrite = cli.bool 'overwrite-roblox' -- overwrite roblox by local changes
local fresh_state = cli.bool 'ignore-conflicts' -- dont fetch roblox state for conflict checking
local scanned_cloud = false

local state_ok, state_result = pcall(state_fs.load_state, STATE_PATH)
local input_ok, input_result = pcall(state_fs.load_input, INPUT_PATH)
local resources

-- login
sync_logger.print_header()

local user_session = auth_guidance.authenticate_user() :: any
local universe_id = if state_ok
	then state_result.universe_id
	elseif INTERACTIVE then prompt.prompt_subject(user_session).universe.universe_id
	else error 'universe expected'

local session, key_info = auth_guidance.authenticate_key(API_KEY, API_KEY ~= nil, universe_id)
if not session or not key_info then return process.exit(1) end

local universe = http.request('GET', `universe/{universe_id}`, function()
	return cloud.universe.get(session, { universe_id = universe_id })
end)
ctx_log.str(`Target universe {c.green}{universe.displayName}{c.reset} {c.dim}({universe_id})`)

-- ensure resources
local function state_from_cloud(input: state.manifest?)
	if not prompt.confirm_reimport(INPUT_PATH) then return end

	local owner: state.owner = if universe.user
		then { user = tonumber(universe.user) :: number, group = nil }
		else { group = tonumber(universe.group) :: number, user = nil }

	local resources = state.build_resources(input or state.create_input(owner), state.create_state(universe_id))

	ctx_log.gap()
	local target = tostring(universe_id)

	key_info = auth_guidance.grant_scope(session, key_info, 'developer-product:read', target)
	import.await_import_products(api.build_product_api(session), universe_id, resources)

	import.await_import_places(api.build_place_api(session, user_session), universe_id, resources)

	key_info = auth_guidance.grant_scope(session, key_info, 'universe:read', target)
	import.await_import_universe(api.build_universe_api(session, user_session), universe_id, resources)

	state_fs.save_resources(resources, INPUT_PATH, STATE_PATH)
	ctx_log.str(`Saved {c.green}{STATE_PATH}{c.reset} and {c.green}{INPUT_PATH}`)

	scanned_cloud = true
	return resources
end
local function input_from_state(lock, universe)
	local owner: state.owner = if universe.user
		then { user = tonumber(universe.user) }
		else { group = tonumber(universe.group) } :: any

	if not prompt.confirm_regen_input(INPUT_PATH, STATE_PATH) then
		return state.build_resources(state.create_input(owner), lock)
	end

	local rebuilt = state_fs.resources_from_lock(lock, owner)
	state_fs.save_resources(rebuilt, INPUT_PATH, STATE_PATH)
	ctx_log.str(`Regenerated {c.green}{INPUT_PATH}{c.reset} from {c.green}{STATE_PATH}`)
	return rebuilt
end

-- resource recovery
if not state_ok and STATE_PATH then
	ctx_log.gap()
	ctx_log.warn(`Couldnt read state, {(tostring(state_result):gsub('^.-:%d+: ', ''))}`)
	resources = state_from_cloud(input_ok and input_result or nil)
elseif not input_ok and INPUT_PATH then
	ctx_log.warn(`Couldnt read input, {(tostring(input_result):gsub('^.-:%d+: ', ''))}`)
	resources = input_from_state(state_result, universe)
else
	resources = state.build_resources(input_result, state_result)
end

if not resources then
	ctx_log.error 'No state loaded'
	process.exit(1)
end

if scanned_cloud then
	if not prompt.prompt_add_overwrite() then return process.exit(0) end
	overwrite = true -- push local changes over the freshly-scanned cloud state
end

ctx_log.gap()

local sync_opts =
	{ universe_id = resources.lock.universe_id, overwrite = overwrite, fresh_state = scanned_cloud or fresh_state }

-- reconcile
local write_target = tostring(resources.lock.universe_id)

local universe_api = api.build_universe_api(session, user_session)
if resources.universe then
	key_info = auth_guidance.grant_scope(session, key_info, 'universe:write', write_target)
	local ok, err = pcall(sync.await_reconcile_universe, universe_api, resources.universe, sync_opts)
	if ok then resources.universe.lock = err end
end

local place_api = api.build_place_api(session, user_session)
if next(resources.places) then
	key_info = auth_guidance.grant_scope(session, key_info, 'universe-places:write', write_target)
end
for _, place in resources.places do
	local ok, err = pcall(sync.await_reconcile_place, place_api, place, sync_opts)
	if ok then place.lock = err end
end

local product_api = api.build_product_api(session)
if next(resources.products) then
	key_info = auth_guidance.grant_scope(session, key_info, 'developer-product:write', write_target)
end
for _, resource in resources.products do
	local ok, err = pcall(sync.await_reconcile_product, product_api, resource, sync_opts)
	if ok then resource.lock = err end
end

if SCAN_CLOUD and not scanned_cloud then state_from_cloud(resources.manifest) end

sync_logger.print_summary()
state_fs.save_resources(resources, INPUT_PATH, STATE_PATH)

process.exit(sync_logger.summary.errors)
