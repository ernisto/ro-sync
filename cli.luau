local task = require '@lune/task'

local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'

local state = require '@lib/state'
local sync = require '@lib/sync'
local sync_logger = require '@lib/sync_logger'
local types = require '@lib/types'

-- cli
local API_KEY = cli.str 'api-key' or env.str 'API_KEY' or error 'missing api key'
local INPUTS_PATH = cli.str 'manifest' or 'cloud.yml'
local LOCK_PATH = cli.str 'state' or 'cloud-state.yml'
local force_fresh_state = cli.bool 'fresh-state'
local detect_new = cli.bool 'detect-new'

local session = cloud.auth.apikey.login(API_KEY)

local function log_http_call<T>(method: string, path: string, fn: () -> T): T
	local ok, result = pcall(fn)
	if ok then
		ctx_log.http(method, path, true, 200)
		return result :: T
	end

	local err = tostring(result)
	local code = tonumber(err:match '%[(%d+)%]')
	local msg = err:match 'Request fail %[%d+%]: (.-)[\n$]' or err:match 'Request fail %[%d+%]: (.+)' or err
	ctx_log.http(method, path, false, code, msg)
	error(result, 0)
end

local api: sync.cloud_api = {
	get = function(product)
		local path = `developer-product/{product.product_id}`
		return log_http_call('GET', path, function()
			return types.from_api_result(cloud.product.get(session, product))
		end)
	end,
	create = function(universe, data)
		local path = `universes/{universe.universe_id}/developer-products`
		return log_http_call('POST', path, function()
			return types.from_api_result(cloud.product.create(session, universe, types.to_api_params(data)))
		end)
	end,
	update = function(product, patch)
		local path = `developer-product/{product.product_id}`
		return log_http_call('PATCH', path, function()
			cloud.product.update(session, product, types.to_api_params(patch))
			return nil
		end)
	end,
}

sync_logger.print_header()

-- main
local resources = state.read_resources(INPUTS_PATH, LOCK_PATH)
local sync_opts = { universe_id = resources.lock.universe_id, force_fresh_state = force_fresh_state }

local remaining = 0
for _, resource in resources.products do
	remaining += 1
	task.spawn(function()
		resource.lock = sync.sync_product(api, resource, sync_opts)
	end)
end
while remaining > 0 do
	task.wait()
end

if detect_new then
	local universe_id = resources.lock.universe_id
	if universe_id == state.UNAVAILABLE_ID then
		for _, product_lock in resources.lock.products do
			universe_id = product_lock.universe_id
			break
		end
	end
	if universe_id == state.UNAVAILABLE_ID then
		ctx_log.warn 'cannot detect new products: universe_id unknown (run a sync with at least one tracked product first)'
	end

	if universe_id ~= state.UNAVAILABLE_ID then
		local known_ids: { [number]: boolean } = {}
		for _, product_lock in resources.lock.products do
			known_ids[product_lock.product_id] = true
		end

		local token: string? = nil
		repeat
			local path = `universes/{universe_id}/developer-products/creator`
			local page = log_http_call('GET', path, function()
				return cloud.product.list(session, { universe_id = universe_id }, { pageToken = token })
			end)
			for _, product in page.developerProducts do
				if known_ids[product.productId] then continue end
				local key = product.name
				if resources.manifest.products[key] then key = `{product.name}_{product.productId}` end

				local manifest_input = { name = product.name }
				local lock_input = {
					name = product.name,
					icon = product.iconImageAssetId and { assetid = product.iconImageAssetId } or nil,
				}
				resources.manifest.products[key] = manifest_input
				resources.lock.products[key] = {
					universe_id = product.universeId,
					product_id = product.productId,
					input = lock_input,
				}
				sync_logger.imported(key, product.productId)
			end
			token = if page.nextPageToken ~= '' then page.nextPageToken else nil
		until token == nil
	end
end

sync_logger.print_summary()
state.save_resources(resources)
