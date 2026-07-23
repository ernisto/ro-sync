local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'
local http = require '@utils/http'
local c = ctx_log.colors

local api = require '@cli/api'
local prompt = require '@cli/prompt'
local state_fs = require '@cli/state_fs'

local import = require '@lib/import'
local sync = require '@lib/sync'
local sync_logger = require '@lib/sync_logger'

-- cli
local API_KEY = cli.str 'api-key' or env.str 'API_KEY' or error 'missing api key'
local INPUTS_PATH = cli.str 'manifest' or 'cloud.yml'
local LOCK_PATH = cli.str 'state' or 'cloud-state.yml'
local force_fresh_state = cli.bool 'fresh-state'
local detect_new = cli.bool 'detect-new'

-- login
local session = cloud.auth.apikey.login(API_KEY)

sync_logger.print_header()
ctx_log.str(`Logged in API Key: {c.green}"{string.sub(API_KEY, 1, 10)}..."`)

-- ensure workspace
if not state_fs.files_exist(INPUTS_PATH) then
	ctx_log.warn(`No manifest/lock found, logging in cookie to bootstrap`)

	local user_session = cloud.auth.cookie.login()
	local subject = prompt.prompt_subject(user_session)

	local resources = state_fs.create_resources(subject.owner, subject.universe and subject.universe.universe_id)
	if subject.universe then
		import.await_import_products(session, subject.universe.universe_id, resources)
		import.await_import_places(user_session, subject.universe.universe_id, resources)
		import.await_import_universe(session, user_session, subject.universe.universe_id, resources)
	end

	state_fs.save_resources(resources, INPUTS_PATH, LOCK_PATH)
	ctx_log.str(`Wrote {c.bold}{INPUTS_PATH}{c.reset} and {c.bold}{LOCK_PATH}`)
	return
end

-- load resources
local resources = state_fs.load_resources(INPUTS_PATH, LOCK_PATH)
if not resources.lock.universe_id or resources.lock.universe_id < 0 then
	return ctx_log.error(`Lock file missing universe_id, delete {LOCK_PATH} to re-bootstrap`)
end

local universe = http.request('GET', `universe/{resources.lock.universe_id}`, function()
	return cloud.universe.get(session, { universe_id = resources.lock.universe_id })
end)
ctx_log.str(`Target universe: {c.bold}{universe.displayName}{c.reset} {c.dim}({resources.lock.universe_id})`)
ctx_log.str ''

local owner = resources.manifest.owner
local creator = if owner.user then { userId = owner.user } else { groupId = owner.group }

local user_session = cloud.auth.cookie.login()
local place_api = api.build_place_api(session, user_session, creator)
local universe_api = api.build_universe_api(session, user_session)
local product_api = api.build_product_api(session)

-- reconcile
local sync_opts = { universe_id = resources.lock.universe_id, force_fresh_state = force_fresh_state }

if resources.universe then
	local ok, err = pcall(sync.await_reconcile_universe, universe_api, resources.universe, sync_opts)
	if ok then resources.universe.lock = err end
end
for _, place in resources.places do
	local ok, err = pcall(sync.await_reconcile_place, place_api, place, sync_opts)
	if ok then place.lock = err end
end
for _, resource in resources.products do
	local ok, err = pcall(sync.await_reconcile_product, product_api, resource, sync_opts)
	if ok then resource.lock = err end
end

if detect_new then
	import.await_import_places(user_session, resources.lock.universe_id, resources)
	import.await_import_universe(session, user_session, resources.lock.universe_id, resources)
	import.await_import_products(session, resources.lock.universe_id, resources)
end

sync_logger.print_summary()
state_fs.save_resources(resources, INPUTS_PATH, LOCK_PATH)
