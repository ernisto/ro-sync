local cloud = require '@pkg/ro_cloud'
local state = require '@lib/state'

-- types
export type product_read = state.product_data & { universe_id: number, product_id: number }
export type place_read = state.place_data & { universe_id: number, place_id: number }

local SOCIAL_MAP: { [string]: string } = {
	facebook = 'facebookSocialLink',
	twitter = 'twitterSocialLink',
	youtube = 'youtubeSocialLink',
	twitch = 'twitchSocialLink',
	discord = 'discordSocialLink',
	roblox_group = 'robloxGroupSocialLink',
	guilded = 'guildedSocialLink',
}
local FLAG_MAP: { [string]: string } = {
	voice_chat = 'voiceChatEnabled',
	desktop = 'desktopEnabled',
	mobile = 'mobileEnabled',
	tablet = 'tabletEnabled',
	console = 'consoleEnabled',
	vr = 'vrEnabled',
}

-- products
local function from_product_api(data: cloud.product): product_read
	local price_info = data.priceInformation
	return {
		universe_id = data.universeId,
		product_id = data.productId,
		icon_file = { assetid = data.iconImageAssetId },
		name = data.name,
		price = price_info.defaultPriceInRobux,
		description = data.description,
		is_for_sale = data.isForSale,
		regional_pricing = table.find(price_info.enabledFeatures, 'RegionalPricing') ~= nil,
		store_page_enabled = data.storePageEnabled,
	}
end
local function to_product_api_params(data: state.product_input)
	local icon = data.icon_file
	return {
		name = data.name,
		price = data.price,
		description = data.description,
		imageFile = icon and icon.content,
		isForSale = data.is_for_sale,
		isRegionalPricingEnabled = data.regional_pricing,
		storePageEnabled = data.store_page_enabled,
	}
end

-- places
local function from_place_api(info: cloud.place_info): state.place_data
	local any_info: any = info -- TODO: check if GET place really returns optional fields
	return { display_name = any_info.displayName, description = any_info.description, server_size = any_info.serverSize }
end
local function to_place_info_params(patch: state.place_input)
	return { displayName = patch.display_name, description = patch.description, serverSize = patch.server_size }
end
-- develop.list_universe_places returns the legacy place shape (name/maxPlayerCount)
local function from_develop_place(data: cloud.place_data): state.place_data
	return { display_name = data.name, description = data.description, server_size = data.maxPlayerCount } :: any
end

-- universe
local function from_universe_api(data: cloud.universe): state.universe_data
	local out = { private_server_price = data.privateServerPriceRobux }

	for snake, camel in SOCIAL_MAP do
		out[snake] = data[camel]
	end
	for snake, camel in FLAG_MAP do
		out[snake] = data[camel]
	end
	return out :: any
end
local function to_universe_params(patch: state.universe_input)
	local params = { privateServerPriceRobux = patch.private_server_price }

	for snake, camel in SOCIAL_MAP do
		if patch[snake] ~= nil then params[camel] = patch[snake] end
	end
	for snake, camel in FLAG_MAP do
		if patch[snake] ~= nil then params[camel] = patch[snake] end
	end
	return params
end

-- module
return table.freeze {
	from_api_result = from_product_api,
	to_api_params = to_product_api_params,
	from_place_api = from_place_api,
	from_develop_place = from_develop_place,
	to_place_info_params = to_place_info_params,
	from_universe_api = from_universe_api,
	to_universe_params = to_universe_params,
}
