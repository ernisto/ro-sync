local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'
local http_log = require '@utils/http_log'
local task = require '@lune/task'
local tbl = require '@utils/tbl'
local c = ctx_log.colors

local prompt = require '@cli/prompt'
local state_fs = require '@cli/state_fs'

local import = require '@lib/import'
local sync = require '@lib/sync'
local sync_logger = require '@lib/sync_logger'
local types = require '@lib/types'

-- cli
local API_KEY = cli.str 'api-key' or env.str 'API_KEY' or error 'missing api key'
local INPUTS_PATH = cli.str 'manifest' or 'cloud.yml'
local LOCK_PATH = cli.str 'state' or 'cloud-state.yml'
local force_fresh_state = cli.bool 'fresh-state'
local detect_new = cli.bool 'detect-new'

-- login
local session = cloud.auth.apikey.login(API_KEY)

-- assets are created asynchronously; poll the returned operation until it resolves to asset data
local function await_asset(operation: cloud.asset_operation): cloud.asset_data
	for _ = 1, 30 do
		if operation.done then return operation.response end
		local op_id = operation.path:match 'operations/(.+)' or error(`malformed operation path '{operation.path}'`)

		task.wait(1)
		operation = http_log.log_http_call('GET', `assets/operations/{op_id}`, function()
			return cloud.asset.get_operation(session, op_id)
		end)
	end
	return error 'asset creation timed out'
end

local product_api: sync.cloud_api = {
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
sync_logger.print_header()
ctx_log.str(`Logged in API Key: {c.green}"{string.sub(API_KEY, 1, 10)}..."`)

-- ensure workspace
if not state_fs.files_exist(INPUTS_PATH) then
	ctx_log.warn(`No manifest/lock found, logging in cookie to bootstrap`)

	local user_session = cloud.auth.cookie.login()
	local subject = prompt.prompt_subject(user_session)

	local resources = state_fs.create_resources(subject.owner, subject.universe and subject.universe.universe_id)
	if subject.universe then
		import.import_products(session, subject.universe.universe_id, resources)
		import.import_places(user_session, subject.universe.universe_id, resources)
		import.import_universe(session, user_session, subject.universe.universe_id, resources)
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

local universe = http_log.log_http_call('GET', `universe/{resources.lock.universe_id}`, function()
	return cloud.universe.get(session, { universe_id = resources.lock.universe_id })
end)
ctx_log.str(`Target universe: {c.bold}{universe.displayName}{c.reset} {c.dim}({resources.lock.universe_id})`)
ctx_log.str ''

-- the develop configuration endpoints (place/universe) are cookie-authenticated, not API-key
local user_session = cloud.auth.cookie.login()

-- universe spans two endpoints: open-cloud (socials/devices/voice/private price) + develop configuration
local universe_api: sync.universe_api = {
	get = function(u)
		local open = types.from_universe_api(http_log.log_http_call('GET', `universe/{u.universe_id}`, function()
			return cloud.universe.get(session, u)
		end))
		local config = types.from_universe_config(
			http_log.log_http_call('GET', `universes/{u.universe_id}/configuration`, function()
				return cloud.universe_configuration.get(user_session, u)
			end)
		)
		return tbl.applied(open, config)
	end,
	update = function(u, patch)
		local applied: { [string]: any } = {}

		local open_params = types.to_universe_params(patch)
		if next(open_params) ~= nil then
			local res = http_log.log_http_call('PATCH', `universe/{u.universe_id}`, function()
				return cloud.universe.update(session, u, open_params)
			end)
			tbl.apply(applied, types.from_universe_api(res))
		end

		local config_params = types.to_universe_config_params(patch)
		if next(config_params) ~= nil then
			local res = http_log.log_http_call('PATCH', `universes/{u.universe_id}/configuration`, function()
				return cloud.universe_configuration.update(user_session, u, config_params)
			end)
			tbl.apply(applied, types.from_universe_config(res :: any))
		end

		return if next(applied) ~= nil then applied else nil
	end,
}

-- creator drives the creationContext required when creating new place assets
local owner = resources.manifest.owner
local creator = if owner.user then { userId = owner.user } else { groupId = owner.group }

local place_api: sync.place_api = {
	create = function(opts, place)
		local file = assert(place.asset_file, 'place create requires a file').content
		local op = http_log.log_http_call('POST', 'assets (Place)', function()
			return cloud.asset.create(
				session,
				{
					assetType = 'Place',
					displayName = place.display_name,
					description = place.description,
					creationContext = { creator = creator },
				} :: any,
				assert(file, 'place file has no content')
			)
		end)

		local asset = await_asset(op)
		return {
			universe_id = opts.universe_id,
			place_id = asset.assetId,
			asset_file = place.asset_file,
			display_name = place.display_name,
			description = place.description,
			server_size = place.server_size,
		} :: any
	end,
	get = function(place)
		return types.from_place_config(http_log.log_http_call('GET', `places/{place.place_id}`, function()
			return cloud.place_configuration.get(user_session, { place_id = place.place_id })
		end))
	end,
	update = function(place, patch)
		if patch.asset_file and patch.asset_file.content then
			http_log.log_http_call('POST', `places/{place.place_id}/versions`, function()
				return cloud.place.upload(session, place, patch.asset_file.content, true)
			end)
		end
		local config = types.to_place_config_params(patch)
		if next(config) ~= nil then
			return types.from_place_config(http_log.log_http_call('PATCH', `places/{place.place_id}`, function()
				return cloud.place_configuration.update(user_session, { place_id = place.place_id }, config)
			end))
		end
		return nil
	end,
}

-- reconcile
local sync_opts = { universe_id = resources.lock.universe_id, force_fresh_state = force_fresh_state }

if resources.universe then
	resources.universe.lock = sync.await_reconcile_universe(universe_api, resources.universe, sync_opts)
end
for _, place in resources.places do
	place.lock = sync.await_reconcile_place(place_api, place, sync_opts)
end
for _, resource in resources.products do
	resource.lock = sync.await_reconcile_product(product_api, resource, sync_opts)
end

if detect_new then import.import_products(session, resources.lock.universe_id, resources) end

sync_logger.print_summary()
state_fs.save_resources(resources, INPUTS_PATH, LOCK_PATH)
