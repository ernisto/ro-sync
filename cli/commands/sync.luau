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

local import = require '@lib/import'
local state = require '@lib/state'
local sync = require '@lib/sync'
local sync_logger = require '@lib/sync_logger'

-- cli
local INTERACTIVE = not env.str 'CI' -- used bu prompt
-- local AUTO_ACCEPT = cli.str 'yes' or cli.str 'y' -- used by prompt

-- local COOKIE = env.str 'ROBLOX_COOKIE' -- used by auth_guidance
local API_KEY = cli.str('api-key', { value = 'KEY', help = 'Open Cloud API key (default: $API_KEY)' })
	or env.str 'API_KEY'

local PUSHES = cli.list('push', { value = 'FILE', help = 'manifest to sync (default: cloud.yml)' })
local INPUT_PATH = if PUSHES and PUSHES[1] then PUSHES[1] else 'cloud.yml'
local STATE_PATH = cli.str 'cache' or 'cloud-state.yml'

local scan_cloud = cli.bool('scan-roblox', { help = 'rescan the whole universe from Roblox' })
local sync_all = cli.bool('all', { help = 'fetch even unchanged resources' })
local overwrite = cli.bool('overwrite-cloud', { help = 'push local changes over Roblox cloud' })
local ignore_cloud = cli.bool('ignore-cloud', { help = 'skip fetching Roblox cloud to update cache/conflicts' })

local scanned_cloud = false

cli.strict()

local state_ok, state_result = pcall(state_fs.load_state, STATE_PATH)
local input_ok, input_result = pcall(state_fs.load_input, INPUT_PATH)

local function merge_input(base: any, extra: any)
	for k, v in extra do
		if type(v) == 'table' and type(base[k]) == 'table' and v[1] == nil then
			merge_input(base[k], v)
		else
			base[k] = v
		end
	end
end
if input_ok and PUSHES then
	for i = 2, #PUSHES do
		local ok, extra = pcall(state_fs.load_input, PUSHES[i])
		if ok then
			merge_input(input_result, extra)
			ctx_log.str(`Merged {c.green}{PUSHES[i]}{c.reset} into {c.green}{INPUT_PATH}`)
		else
			ctx_log.warn(`Couldnt read {PUSHES[i]}, {(tostring(extra):gsub('^.-:%d+: ', ''))}`)
		end
	end
end
local resources

-- login
sync_logger.print_header()

local user_session = auth_guidance.authenticate_user() :: any
local universe_id = if state_ok
	then state_result.universe_id
	elseif not user_session then ctx_log.throw 'you are not logged as user to import/create a universe'
	elseif INTERACTIVE then prompt.prompt_subject(user_session).universe.universe_id
	else ctx_log.throw 'universe expected'

local api_session, key_info = auth_guidance.authenticate_key(API_KEY, API_KEY ~= nil, universe_id)
if not api_session or not key_info then return process.exit(1) end

local session: cloud.session = api_session :: any
session.cookie_state = user_session and user_session.cookie_state

local universe = http.call(cloud.universe.get, session, { universe_id = universe_id }, nil)
ctx_log.str(`Target universe {c.green}{universe.displayName}{c.reset} {c.dim}({universe_id})`)

-- ensure resources
local function state_from_cloud(input: state.manifest?)
	if not scan_cloud and not prompt.confirm_reimport(INPUT_PATH) then return end

	local owner: state.owner = if universe.user
		then { user = tonumber(universe.user:match '%d+') :: number, group = nil }
		else { group = tonumber((universe.group :: string):match '%d+') :: number, user = nil }

	local resources = state.build_resources(input or state.create_input(owner), state.create_state(universe_id))

	ctx_log.gap()
	import.await_import_all(session, resources, universe_id, prompt.prompt_import_key)

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

if not resources then ctx_log.throw 'No state loaded' end

if scanned_cloud then
	if not input_ok or not (overwrite or prompt.prompt_add_overwrite()) then return process.exit(0) end
	overwrite = true -- push local changes over the freshly-scanned cloud state
end

ctx_log.gap()
sync.await_reconcile_all(resources, {
	ignore_cloud = ignore_cloud,
	overwrite = overwrite,
	sync_all = sync_all,
	session = session,
})

if scan_cloud and not scanned_cloud then state_from_cloud(resources.manifest) end

sync_logger.print_summary()
state_fs.save_resources(resources, INPUT_PATH, STATE_PATH)

return if sync_logger.summary.errors == 0 then process.exit(0) else process.exit(1)
