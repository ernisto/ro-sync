local cloud = require '@pkg/ro_cloud'
local state = require '@lib/state'

-- types
export type flat_product = {
	universe_id: number,
	product_id: number,
	icon_id: number,
	name: string,
	price: number?,
	description: string?,
	is_for_sale: boolean?,
	regional_pricing: boolean?,
	store_page_enabled: boolean?,
}

-- functions
local function from_api(data: cloud.product): flat_product
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
end

local function to_api_params(data: state.product_input & { icon_bytes: buffer? })
	return {
		name = data.name,
		price = data.price,
		description = data.description,
		imageFile = data.icon_bytes,
		isForSale = data.is_for_sale,
		isRegionalPricingEnabled = data.regional_pricing,
		storePageEnabled = data.store_page_enabled,
	}
end

-- module
return table.freeze {
	from_api_result = from_api,
	to_api_params = to_api_params,
}
