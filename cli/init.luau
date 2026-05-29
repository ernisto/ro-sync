local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'
local http_log = require '@utils/http_log'
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

local function place_identity(place: any)
	return { universe_id = place.universe_id, place_id = place.place_id }
end
local place_api: sync.place_api = {
	get = function(place)
		local path = `universes/{place.universe_id}/places/{place.place_id}`
		return types.from_place_api(http_log.log_http_call('GET', path, function()
			return cloud.place.get_info(session, place_identity(place))
		end))
	end,
	update = function(place, patch)
		local id = place_identity(place)
		if patch.file_asset and patch.file_asset.content then
			http_log.log_http_call('POST', `places/{place.place_id}/versions`, function()
				return cloud.place.upload(session, id, patch.file_asset.content, true)
			end)
		end
		local settings = types.to_place_info_params(patch)
		if next(settings) ~= nil then
			http_log.log_http_call('PATCH', `universes/{place.universe_id}/places/{place.place_id}`, function()
				return cloud.place.update_info(session, id, settings)
			end)
		end
	end,
}

local universe_api: sync.universe_api = {
	get = function(u)
		return types.from_universe_api(http_log.log_http_call('GET', `universe/{u.universe_id}`, function()
			return cloud.universe.get(session, { universe_id = u.universe_id })
		end))
	end,
	-- the vendored universe.update omits updateMask + body, so PATCH directly
	update = function(u, patch)
		local params = types.to_universe_params(patch)
		local url = `https://apis.roblox.com/cloud/v2/universes/{u.universe_id}`
		http_log.log_http_call('PATCH', `universe/{u.universe_id}`, function()
			return cloud.auth.request_json(session, 'PATCH', url, { updateMask = cloud.auth.mask_from(params) }, params)
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
	if subject.universe then import.import(session, subject.universe.universe_id, resources) end

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

-- reconcile
local sync_opts = { universe_id = resources.lock.universe_id, force_fresh_state = force_fresh_state }

for _, resource in resources.products do
	resource.lock = sync.await_reconcile_product(api, resource, sync_opts)
end
for _, place in resources.places do
	place.lock = sync.await_reconcile_place(place_api, place, sync_opts)
end
if resources.universe then
	resources.universe.lock = sync.await_reconcile_universe(universe_api, resources.universe, sync_opts)
end

if detect_new then import.import(session, resources.lock.universe_id, resources) end

sync_logger.print_summary()
state_fs.save_resources(resources, INPUTS_PATH, LOCK_PATH)
