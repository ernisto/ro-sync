local fs = require '@lune/fs'
local serde = require '@lune/serde'
local task = require '@lune/task'

local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local env = require '@utils/env'

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
local api: sync.cloud_api = {
	get = function(product)
		local data = cloud.product.get(session, product)
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
		local result = cloud.product.create(session, universe, {
			name = data.name,
			price = data.price,
			description = data.description,
			imageFile = data.icon_bytes,
			isForSale = data.is_for_sale,
			isRegionalPricingEnabled = data.regional_pricing,
		})
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
		cloud.product.update(session, product, {
			name = patch.name,
			price = patch.price,
			description = patch.description,
			imageFile = patch.icon_bytes,
			isForSale = patch.is_for_sale,
			isRegionalPricingEnabled = patch.regional_pricing,
			store_page_enabled = patch.store_page_enabled,
		})
	end,
}

-- main
local opts: sync.sync_opts = {
	universe_id = lock.universe_id,
	force_fresh_state = force_fresh_state,
}

local remaining = 0
for key, item in inputs.products do
	remaining += 1
	task.spawn(xpcall, function()
		lock.products[key] = sync.sync_product(key, item, lock.products[key], api, opts)
		remaining -= 1
	end, function(err)
		warn(`  failed {key}: {debug.traceback(err)}`)
		remaining -= 1
	end)
end

while remaining > 0 do
	task.wait()
end

fs.writeFile(LOCK_PATH, serde.encode('yaml', lock, true))
fs.writeFile(INPUTS_PATH, serde.encode('yaml', inputs, true))
