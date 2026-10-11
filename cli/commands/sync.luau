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

local base = require '@lib/resources/base'
local icon_res = require '@lib/resources/icon'
local pass_res = require '@lib/resources/pass'
local place_res = require '@lib/resources/place'
local product_res = require '@lib/resources/product'
local thumbnail_res = require '@lib/resources/thumbnail'
local universe_res = require '@lib/resources/universe'

-- cli
-- local COOKIE = env.str 'ROBLOX_COOKIE' -- used by auth_guidance
-- local AUTO_ACCEPT = cli.str 'yes' or cli.str 'y' -- used by prompt
local INTERACTIVE = not env.str 'CI' -- used bu prompt

local API_KEY = cli.str('api-key', { value = 'KEY', help = 'Open Cloud API key (default: $API_KEY)' })
	or env.str 'API_KEY'
local pushes = cli.list('push', { value = 'FILE', help = 'manifest to sync (default: cloud.yml)' })
local INPUT_PATH = if pushes and pushes[1] then pushes[1] else 'cloud.yml'
local STATE_PATH = cli.str 'cache' or 'cloud-state.yml'
local SCAN_CLOUD = cli.bool('scan-roblox', { help = 'rescan the whole universe from Roblox' })

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
if input_ok and pushes then
	for i = 2, #pushes do
		local ok, extra = pcall(state_fs.load_input, pushes[i])
		if ok then
			merge_input(input_result, extra)
			ctx_log.str(`Merged {c.green}{pushes[i]}{c.reset} into {c.green}{INPUT_PATH}`)
		else
			ctx_log.warn(`Couldnt read {pushes[i]}, {(tostring(extra):gsub('^.-:%d+: ', ''))}`)
		end
	end
end
local resources

-- login
sync_logger.print_header()

local user_session = auth_guidance.authenticate_user() :: any
local universe_id = if state_ok
	then state_result.universe_id
	elseif INTERACTIVE then prompt.prompt_subject(user_session).universe.universe_id
	else error 'universe expected'

local api_session, key_info = auth_guidance.authenticate_key(API_KEY, API_KEY ~= nil, universe_id)
if not api_session or not key_info then return process.exit(1) end

local session: base.session = api_session :: any
session.cookie_state = user_session and user_session.cookie_state

local universe = http.call(cloud.universe.get, session, { universe_id = universe_id }, nil)
ctx_log.str(`Target universe {c.green}{universe.displayName}{c.reset} {c.dim}({universe_id})`)

-- ensure resources
local function state_from_cloud(input: state.manifest?)
	if not prompt.confirm_reimport(INPUT_PATH) then return end

	local owner: state.owner = if universe.user
		then { user = tonumber(universe.user:match '%d+') :: number, group = nil }
		else { group = tonumber((universe.group :: string):match '%d+') :: number, user = nil }

	local resources = state.build_resources(input or state.create_input(owner), state.create_state(universe_id))

	ctx_log.gap()
	pcall(function()
		import.await_import_places(place_res, session, universe_id, resources)
	end)

	pcall(function()
		import.await_import_universe(universe_res, session, universe_id, resources)
	end)

	pcall(function()
		import.await_import_products(product_res, session, universe_id, resources)
	end)

	pcall(function()
		import.await_import_passes(pass_res, session, universe_id, resources)
	end)

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
	if not input_ok or not prompt.prompt_add_overwrite() then return process.exit(0) end
	overwrite = true -- push local changes over the freshly-scanned cloud state
end

ctx_log.gap()

local sync_opts = {
	universe_id = resources.lock.universe_id,
	overwrite = overwrite,
	sync_all = sync_all,
	ignore_cloud = ignore_cloud,
	session = session,
}

-- reconcile
if resources.universe then
	local ok, err = pcall(sync.await_reconcile_universe, universe_res, resources.universe, sync_opts)
	if ok then resources.universe.lock = err end
end

for _, place in resources.places do
	local ok, err = pcall(sync.await_reconcile_place, place_res, place, sync_opts)
	if ok then place.lock = err end
end

for _, resource in resources.products do
	local ok, err = pcall(sync.await_reconcile_product, product_res, resource, sync_opts)
	if ok then resource.lock = err end
end

for _, resource in resources.passes do
	local ok, err = pcall(sync.await_reconcile_pass, pass_res, resource, sync_opts)
	if ok then resource.lock = err end
end

for _, resource in resources.thumbnails do
	local ok, err = pcall(sync.await_reconcile_thumbnail, thumbnail_res, resource, sync_opts)
	if ok then resource.lock = err end
end

if resources.manifest.thumbnails then
	local kept = {}
	for _, resource in resources.thumbnails do
		local file = resource.lock and resource.lock.input.image_file
		if file then kept[file.hash] = true end
	end
	for hash, lock in resources.lock.thumbnails do
		if kept[hash] then continue end
		local ok, err = pcall(thumbnail_res.delete, session, lock)
		if ok then
			resources.lock.thumbnails[hash] = nil
			ctx_log.str(`deleted thumbnail {lock.thumbnail_id}`)
		else
			ctx_log.warn(`couldnt delete thumbnail {lock.thumbnail_id}: {err}`)
		end
	end
end

if #resources.thumbnails > 0 then
	local ids = {}
	for _, resource in resources.thumbnails do
		if resource.lock then table.insert(ids, resource.lock.thumbnail_id) end
	end
	local ok, err = pcall(thumbnail_res.reorder, session, sync_opts.universe_id, ids)
	if not ok then ctx_log.warn(`couldnt reorder thumbnails: {err}`) end
end

if resources.icon then
	local ok, err = pcall(sync.await_reconcile_icon, icon_res, resources.icon, sync_opts)
	if ok then resources.icon.lock = err end
end

if SCAN_CLOUD and not scanned_cloud then state_from_cloud(resources.manifest) end

sync_logger.print_summary()
state_fs.save_resources(resources, INPUT_PATH, STATE_PATH)

return process.exit(sync_logger.summary.errors)
