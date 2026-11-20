local args = require '@cli/args'
local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
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
local INTERACTIVE = args.INTERACTIVE

local API_KEY = args.API_KEY

-- `--flag` alone or `--flag FILE`: presence and its files
local function optional_files(name: string, opts: any): (boolean, { string })
	local files = cli.list(name, opts)
	return files ~= nil or cli.bool(name), files or {}
end

-- args parse before this spec exists, so `--push a.yml` swallows the file as a value; fold it back in
local MODE = 'Mode Options'
local MANIFESTS = cli.list 'push' or {}
local PUSH = cli.bool('push', { group = MODE, help = 'Update cloud with the manifests' }) or #MANIFESTS > 0
local DRY = cli.bool('dry', { group = MODE, help = "Don't push or write any file" })
for i = 2, math.huge do
	local file = cli.str(i)
	if not file then break end
	table.insert(MANIFESTS, file)
end
local PULL, PULLS = optional_files('pull', {
	value = 'FILE',
	help = 'Fetch cloud before update and write its version to FILE (none: only the cache)',
})
local PULL_NEW, PULL_NEWS = optional_files('pull-new', {
	value = 'FILE',
	help = 'Fetch every cloud resource and write new ones into FILE (default: cloud.yml)',
})
local RESOLVE_TO = cli.str('resolve-to', { value = 'SIDE', help = 'Resolve conflicts with cloud or local values' })

local INPUT_PATH = MANIFESTS[1] or 'cloud.yml'
local PULL_PATH = PULLS[1]
local PULL_NEW_PATH = PULL_NEWS[1] or INPUT_PATH
local STATE_PATH = cli.str 'cache' or 'cloud-state.yml'

cli.strict()
if RESOLVE_TO and RESOLVE_TO ~= 'cloud' and RESOLVE_TO ~= 'local' then
	cli.fail(`--resolve-to must be 'cloud' or 'local', got '{RESOLVE_TO}'`)
end
local resolve_to: sync.side? = RESOLVE_TO :: any

if PUSH and DRY then cli.fail '--push and --dry exclude each other' end

local mode: sync.sync_mode = if PUSH then 'push' elseif DRY then 'dry' else 'receive'

local scanned_cloud = false
local scan_cloud = PULL_NEW

local state_ok, state_result = pcall(state_fs.load_lock, STATE_PATH)
local input_ok, input_result = pcall(state_fs.load_input, INPUT_PATH)

local function reason(err: unknown): string
	local first_line = tostring(err):match '^[^\n]*' :: string
	return (first_line:gsub('^.-:%d+: ', ''))
end

if input_ok then
	for i = 2, #MANIFESTS do
		local ok, extra = pcall(state_fs.load_input, MANIFESTS[i])
		if ok then
			state_fs.merge_input(input_result, extra)
			ctx_log.str(`Merged {c.green}{MANIFESTS[i]}{c.reset} into {c.green}{INPUT_PATH}`)
		else
			ctx_log.warn(`Couldnt read {MANIFESTS[i]}, {reason(extra)}`)
		end
	end
end

-- login
sync_logger.print_header()

if not state_ok then
	ctx_log.warn(`Couldnt read state '{STATE_PATH}', {reason(state_result)}`)
	if not prompt.confirm_import_universe() then return process.exit(1) end

	scan_cloud = true
	ctx_log.gap()
end

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
if state_ok then state_fs.await_load_extends(state_result, session) end

local function save(res: state.resources, manifest_path: string)
	if mode ~= 'dry' then state_fs.save_resources(res, manifest_path, STATE_PATH, session) end
end

local universe = http.call(cloud.universe.get, session, { universe_id = universe_id }, nil)
ctx_log.str(`Target universe {c.green}{universe.displayName}{c.reset} {c.dim}({universe_id})`)

-- ensure resources
local resources

-- universe.user / universe.group come as "users/123" / "groups/456"
local function owner_of(universe: any): state.owner
	local id = tonumber(((universe.user or universe.group) :: string):match '%d+')
	if not id then error(`universe has no owner id: {universe.user or universe.group}`, 2) end

	return if universe.user then { user = id, group = nil } else { group = id, user = nil }
end

local function state_from_cloud(input: state.manifest?)
	if not scan_cloud and not prompt.confirm_reimport(INPUT_PATH) then return end

	local owner = owner_of(universe)
	local fresh = state.build_resources(input or state.create_input(owner), state.create_state(universe_id))

	ctx_log.gap()
	import.await_import_all(session, fresh, universe_id, prompt.prompt_import_key)
	fresh = state.build_resources(fresh.manifest, fresh.lock)

	save(fresh, PULL_NEW_PATH)
	ctx_log.str(`Saved {c.green}{STATE_PATH}{c.reset} and {c.green}{PULL_NEW_PATH}`)

	scanned_cloud = true
	return fresh
end
local function input_from_state(lock, universe)
	local owner = owner_of(universe)

	if not prompt.confirm_regen_input(INPUT_PATH, STATE_PATH) then
		return state.build_resources(state.create_input(owner), lock)
	end

	local rebuilt = state_fs.resources_from_lock(lock, owner)
	save(rebuilt, INPUT_PATH)

	ctx_log.str(`Regenerated {c.green}{INPUT_PATH}{c.reset} from {c.green}{STATE_PATH}`)
	return rebuilt
end

-- resource recovery
if not state_ok then
	ctx_log.gap()
	resources = state_from_cloud(input_ok and input_result or nil)
elseif not input_ok then
	ctx_log.warn(`Couldnt read input, {reason(input_result)}`)
	resources = input_from_state(state_result, universe)
else
	resources = state.build_resources(input_result, state_result)
end

if not resources then ctx_log.throw 'No state loaded' end

if scanned_cloud then
	if not input_ok or mode ~= 'push' or not (resolve_to == 'local' or prompt.prompt_add_overwrite()) then
		return process.exit(0)
	end
	resolve_to = 'local' -- push local changes over the freshly-scanned cloud state
end

local lock = resources.lock
local snapshot = {
	universe = lock.universe and table.clone(lock.universe),
	icon = lock.icon and table.clone(lock.icon),
	thumbnails = table.clone(lock.thumbnails),
	products = table.clone(lock.products),
	passes = table.clone(lock.passes),
	places = table.clone(lock.places),
	configs = table.clone(lock.configs),
	assets = lock.assets and table.clone(lock.assets),
	universe_id = lock.universe_id,
}

if scan_cloud and not scanned_cloud then
	ctx_log.gap()
	import.await_import_all(session, resources, universe_id, prompt.prompt_import_key)
	resources = state.build_resources(resources.manifest, lock)
end

ctx_log.gap()
sync.await_reconcile_all(resources, {
	ignore_cloud = not PULL,
	resolve_to = resolve_to,
	mode = mode,
	session = session,
	snapshot = snapshot,
})

sync_logger.print_summary()
save(resources, if PULL_NEW then PULL_NEW_PATH else INPUT_PATH)
if PULL_PATH and mode ~= 'dry' then
	state_fs.save_manifest(state_fs.resources_from_lock(resources.lock, owner_of(universe)).manifest, PULL_PATH)
	ctx_log.str(`Wrote cloud version to {c.green}{PULL_PATH}`)
end

return if sync_logger.summary.errors == 0 then process.exit(0) else process.exit(1)
