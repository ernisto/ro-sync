local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'
local http_log = require '@utils/http_log'
local stdio = require '@lune/stdio'
local c = ctx_log.colors

local import = require '@lib/import'
local state_fs = require '@lib/state_fs'
local sync = require '@lib/sync'
local sync_logger = require '@lib/sync_logger'
local types = require '@lib/types'

-- cli
local API_KEY = cli.str 'api-key' or env.str 'API_KEY' or error 'missing api key'
local INPUTS_PATH = cli.str 'manifest' or 'cloud.yml'
local LOCK_PATH = cli.str 'state' or 'cloud-state.yml'
local force_fresh_state = cli.bool 'fresh-state'
local detect_new = cli.bool 'detect-new'

-- defs
local session = cloud.auth.apikey.login(API_KEY)
local api: sync.cloud_api = {
	get = function(product)
		local path = `developer-product/{product.product_id}`
		return types.from_api_result(http_log.log_http_call('GET', path, function()
			return cloud.product.get(session, product)
		end))
	end,
	create = function(universe, data)
		local path = `universes/{universe.universe_id}/developer-products`
		return types.from_api_result(http_log.log_http_call('POST', path, function()
			return cloud.product.create(session, universe, types.to_api_params(data))
		end))
	end,
	update = function(product, patch)
		local path = `developer-product/{product.product_id}`
		return http_log.log_http_call('PATCH', path, function()
			return cloud.product.update(session, product, types.to_api_params(patch))
		end)
	end,
}

-- functions
local function prompt_creator(session: cloud.cookie_session): cloud.dev_group?
	local groups_res = cloud.develop.get_groups(session)
	assert(groups_res.ok, groups_res.message)

	local user_res = cloud.auth.get_user_info(session)
	local user = assert(user_res.ok and user_res.body, user_res.message)

	local groups = groups_res.body.data
	local options = { `@{user.name} ({user.id})` }

	for _, group in groups do
		table.insert(options, `{group.name} ({group.id})`)
	end

	local option = stdio.prompt('select', 'Select a creator', options)
	return option and option > 1 and groups[option - 1]
end
local function prompt_universe(session: cloud.cookie_session, universes: { cloud.dev_universe }): cloud.dev_universe
	local options = { 'Create a new universe' }
	for _, universe in universes do
		table.insert(options, `{universe.name} ({universe.id})`)
	end

	local option = stdio.prompt('select', 'Select a place to import', options)
	return option and option > 1 and universes[option - 1]
end

-- load resources
local resources = state_fs.load_resources(INPUTS_PATH, LOCK_PATH)
assert(resources.lock.universe_id)

if not resources.lock.universe_id or resources.lock.universe_id < 0 then
	ctx_log.warn(`Couldnt find a target universe, logging in local cookie to help our prompt`)

	local user_session = cloud.auth.cookie.login()
	local group = prompt_creator(user_session)

	local query = { group_id = group and group.id, cursor = nil } :: any
	local universes: { cloud.dev_universe } = {}

	repeat
		local universes_res = if group
			then cloud.develop.get_group_universes(user_session, query)
			else cloud.develop.get_user_universes(user_session, query)

		assert(universes_res.ok, universes_res.message)
		for _, universe in universes_res.body.data :: any do
			table.insert(universes, universe)
		end

		query.cursor = if universes_res.body.nextPageCursor == query.cursor
			then nil
			else universes_res.body.nextPageCursor
	until query.cursor == nil

	local universe = prompt_universe(user_session, universes)
	if universe then resources.lock.universe_id = universe.id end

	return
end

-- start
local sync_opts = { universe_id = resources.lock.universe_id, force_fresh_state = force_fresh_state }
local universe = http_log.log_http_call('GET', `universe/{resources.lock.universe_id}`, function()
	return cloud.universe.get(session, { universe_id = resources.lock.universe_id })
end)

sync_logger.print_header()
ctx_log.str(`Logged in API Key: {c.green}"{string.sub(API_KEY, 1, 10)}..."`)
ctx_log.str(`Target universe: {c.bold}{universe.displayName}{c.reset} {c.dim}({resources.lock.universe_id})`)
ctx_log.str ''

for _, resource in resources.products do
	resource.lock = sync.await_reconcile_product(api, resource, sync_opts)
end

if detect_new then import.import(session, resources.lock.universe_id, resources) end

sync_logger.print_summary()
state_fs.save_resources(resources, INPUTS_PATH, LOCK_PATH)
