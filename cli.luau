local fs = require '@lune/fs'
local serde = require '@lune/serde'
local task = require '@lune/task'

local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'
local sync_logger = require '@lib/sync_logger'

local state = require '@lib/state'
local sync = require '@lib/sync'

-- cli
local API_KEY = cli.str 'api-key' or env.str 'API_KEY' or error 'missing api key'
local INPUTS_PATH = cli.str 'manifest' or 'cloud.yml'
local LOCK_PATH = cli.str 'state' or 'cloud-state.yml'
local force_fresh_state = cli.bool 'fresh-state'

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
		local data = log_http_call('GET', path, function()
			return cloud.product.get(session, product)
		end)
		local price_info = data.priceInformation
		return {
			universe_id = data.universeId,
			product_id = data.productId,
			icon_id = data.iconImageAssetId,
			name = data.name,
			price = price_info and price_info.defaultPriceInRobux,
			description = data.description,
			is_for_sale = data.isForSale,
			regional_pricing = price_info and table.find(price_info.enabledFeatures, 'RegionalPricing') ~= nil,
			store_page_enabled = data.storePageEnabled,
		}
	end,
	create = function(universe, data)
		local path = `universes/{universe.universe_id}/developer-products`
		local result = log_http_call('POST', path, function()
			return cloud.product.create(session, universe, {
				name = data.name,
				price = data.price,
				description = data.description,
				imageFile = data.icon_bytes,
				isForSale = data.is_for_sale,
				isRegionalPricingEnabled = data.regional_pricing,
			})
		end)
		local price_info = result.priceInformation
		return {
			universe_id = result.universeId,
			product_id = result.productId,
			icon_id = result.iconImageAssetId,
			name = result.name,
			price = price_info and price_info.defaultPriceInRobux,
			description = result.description,
			is_for_sale = result.isForSale,
			regional_pricing = price_info and table.find(price_info.enabledFeatures, 'RegionalPricing') ~= nil,
			store_page_enabled = result.storePageEnabled,
		}
	end,
	update = function(product, patch)
		local path = `developer-product/{product.product_id}`
		log_http_call('PATCH', path, function()
			cloud.product.update(session, product, {
				name = patch.name,
				price = patch.price,
				description = patch.description,
				imageFile = patch.icon_bytes,
				isForSale = patch.is_for_sale,
				isRegionalPricingEnabled = patch.regional_pricing,
				store_page_enabled = patch.store_page_enabled,
			})
			return nil
		end)
	end,
}

-- main
sync_logger.print_header()

local counts = { creates = 0, updates = 0, noops = 0, errors = 0, conflicts = 0 }
local remaining = 0

local opts: sync.sync_opts = {
	universe_id = lock.universe_id,
	force_fresh_state = force_fresh_state,
}

for key, item in inputs.products do
	remaining += 1
	task.spawn(function()
		ctx_log.init(key)

		local ok, err = xpcall(function()
			lock.products[key] = sync.sync_product(key, item, lock.products[key], api, opts)
		end, debug.traceback)

		if ok then
			local action = ctx_log.get_action()
			if action == 'create' then
				counts.creates += 1
			elseif action == 'update' then
				counts.updates += 1
			else
				counts.noops += 1
			end
			counts.conflicts += ctx_log.get_conflicts()
		else
			local err_msg = tostring(err)
			ctx_log.error(err_msg:match '^(.-)\n' or err_msg, err_msg)
			ctx_log.done(false)
			counts.errors += 1
		end

		remaining -= 1
	end)
end

while remaining > 0 do
	task.wait()
end

fs.writeFile(LOCK_PATH, serde.encode('yaml', lock, true))
fs.writeFile(INPUTS_PATH, serde.encode('yaml', inputs, true))

sync_logger.print_summary(counts.creates, counts.updates, counts.noops, counts.errors, counts.conflicts)
