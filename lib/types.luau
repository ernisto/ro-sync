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
local UNIVERSE_CONFIG_MAP: { [string]: string } = {
	is_for_sale = 'isForSale',
	price = 'price',
	allow_private_servers = 'allowPrivateServers',
	genre = 'genre',
	is_friends_only = 'isFriendsOnly',
	is_archived = 'isArchived',
	is_mesh_texture_api_access_allowed = 'isMeshTextureApiAccessAllowed',
}
local PLACE_CONFIG_MAP: { [string]: string } = {
	display_name = 'name',
	description = 'description',
	server_size = 'maxPlayerCount',
	social_slot_type = 'socialSlotType',
	custom_social_slots_count = 'customSocialSlotsCount',
	allow_copying = 'allowCopying',
	allowed_gear_types = 'allowedGearTypes',
	is_all_genres_allowed = 'isAllGenresAllowed',
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

local function from_place_config(data: cloud.place_data): state.place_data
	local out: any = {}
	for snake, camel in PLACE_CONFIG_MAP do
		out[snake] = (data :: any)[camel]
	end
	return out
end
local function to_place_config_params(patch: state.place_input): cloud.place_patch
	local params: any = {}
	for snake, camel in PLACE_CONFIG_MAP do
		if patch[snake] ~= nil then params[camel] = patch[snake] end
	end
	return params
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

local function from_universe_config(data: cloud.universe_configuration_data): state.universe_data
	local out: any = {}
	for snake, camel in UNIVERSE_CONFIG_MAP do
		out[snake] = (data :: any)[camel]
	end
	-- GET exposes studio access as `isStudioAccessToApisAllowed`; the PATCH echo uses `studioAccessToApisAllowed`
	local any: any = data
	out.studio_access_to_apis_allowed = if any.isStudioAccessToApisAllowed ~= nil
		then any.isStudioAccessToApisAllowed
		else any.studioAccessToApisAllowed
	return out
end
local function to_universe_config_params(patch: state.universe_input): cloud.universe_settings_patch
	local params: any = {}
	for snake, camel in UNIVERSE_CONFIG_MAP do
		if patch[snake] ~= nil then params[camel] = patch[snake] end
	end
	if patch.studio_access_to_apis_allowed ~= nil then
		params.studioAccessToApisAllowed = patch.studio_access_to_apis_allowed
	end
	return params
end

-- module
return table.freeze {
	from_api_result = from_product_api,
	to_api_params = to_product_api_params,
	from_place_config = from_place_config,
	to_place_config_params = to_place_config_params,
	from_universe_api = from_universe_api,
	to_universe_params = to_universe_params,
	from_universe_config = from_universe_config,
	to_universe_config_params = to_universe_config_params,
}
