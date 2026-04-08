local fs = require '@lune/fs'
local serde = require '@lune/serde'
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

local inputs = state.read_inputs(INPUTS_PATH)
local lock = state.read_lock(LOCK_PATH)

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
local summary = { creates = 0, updates = 0, noops = 0, errors = 0, conflicts = 0, imported = 0 }
local sync_opts = { universe_id = lock.universe_id, force_fresh_state = force_fresh_state, summary = summary }

local remaining = 0
for key, item in inputs.products do
	remaining += 1
	task.spawn(function()
		local ok = ctx_log.try_result(function()
			lock.products[key] = sync.sync_product(key, item, lock.products[key], api, sync_opts)
		end)
		if not ok then
			summary.errors += 1
		end
		remaining -= 1
	end)
end

while remaining > 0 do
	task.wait()
end

if detect_new then
	local universe_id = lock.universe_id
	if universe_id == state.UNAVAILABLE_ID then
		for _, product_lock in lock.products do
			universe_id = product_lock.universe_id
			break
		end
	end
	if universe_id == state.UNAVAILABLE_ID then
		ctx_log.warn 'cannot detect new products: universe_id unknown (run a sync with at least one tracked product first)'
	end

	if universe_id ~= state.UNAVAILABLE_ID then
		local known_ids: { [number]: boolean } = {}
		for _, product_lock in lock.products do
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
				if inputs.products[key] then key = `{product.name}_{product.productId}` end

				local input = { name = product.name }
				inputs.products[key] = input
				lock.products[key] = {
					universe_id = product.universeId,
					product_id = product.productId,
					icon_id = product.iconImageAssetId,
					icon_hash = nil,
					input = input,
				}
				sync_logger.print_imported(key, product.productId)
				summary.imported += 1
			end
			token = if page.nextPageToken ~= '' then page.nextPageToken else nil
		until token == nil
	end
end

fs.writeFile(LOCK_PATH, serde.encode('yaml', lock, true))
fs.writeFile(INPUTS_PATH, serde.encode('yaml', inputs, true))

sync_logger.print_summary(summary)
