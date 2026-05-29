local cloud = require '@pkg/ro_cloud'
local state = require '@lib/state'

-- types
export type flat_product = {
	universe_id: number,
	product_id: number,
	icon: state.file_lock?,
	name: string,
	price: number?,
	description: string?,
	is_for_sale: boolean?,
	regional_pricing: boolean?,
	store_page_enabled: boolean?,
}
export type flat_place = {
	display_name: string?,
	description: string?,
	server_size: number?,
}
export type flat_universe = {
	facebook: state.social_link?,
	twitter: state.social_link?,
	youtube: state.social_link?,
	twitch: state.social_link?,
	discord: state.social_link?,
	roblox_group: state.social_link?,
	guilded: state.social_link?,
	voice_chat: boolean?,
	desktop: boolean?,
	mobile: boolean?,
	tablet: boolean?,
	console: boolean?,
	vr: boolean?,
	private_server_price: number?,
}

-- snake_case (manifest) <-> camelCase (open cloud) field maps
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
local function from_api(data: cloud.product): flat_product
	local price_info = data.priceInformation
	return {
		universe_id = data.universeId,
		product_id = data.productId,
		icon = data.iconImageAssetId and { assetid = data.iconImageAssetId } or nil,
		name = data.name,
		price = price_info and price_info.defaultPriceInRobux,
		description = data.description,
		is_for_sale = data.isForSale,
		regional_pricing = price_info and table.find(price_info.enabledFeatures, 'RegionalPricing') ~= nil,
		store_page_enabled = data.storePageEnabled,
	}
end
local function to_api_params(data: state.product_input)
	local icon = data.icon_file :: any
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
local function from_place_api(info: cloud.place_info): flat_place
	return { display_name = info.displayName, description = info.description, server_size = info.serverSize }
end
-- nil fields drop out of the table, so the caller's updateMask covers only what changed
local function to_place_info_params(patch: state.place_input)
	return { displayName = patch.display_name, description = patch.description, serverSize = patch.server_size }
end

-- universe
local function from_universe_api(data: cloud.universe): flat_universe
	local out: { [string]: any } = {}
	for snake, camel in SOCIAL_MAP do
		out[snake] = (data :: any)[camel]
	end
	for snake, camel in FLAG_MAP do
		out[snake] = (data :: any)[camel]
	end
	out.private_server_price = data.privateServerPriceRobux
	return out :: any
end
local function to_universe_params(patch: state.universe_input)
	local params: { [string]: any } = {}
	for snake, camel in SOCIAL_MAP do
		if (patch :: any)[snake] ~= nil then params[camel] = (patch :: any)[snake] end
	end
	for snake, camel in FLAG_MAP do
		if (patch :: any)[snake] ~= nil then params[camel] = (patch :: any)[snake] end
	end
	if patch.private_server_price ~= nil then params.privateServerPriceRobux = patch.private_server_price end
	return params
end

-- module
return table.freeze {
	from_api_result = from_api,
	to_api_params = to_api_params,
	from_place_api = from_place_api,
	to_place_info_params = to_place_info_params,
	from_universe_api = from_universe_api,
	to_universe_params = to_universe_params,
}
