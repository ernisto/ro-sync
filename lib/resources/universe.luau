local cloud = require '@pkg/ro_cloud'
local http = require '@utils/http'
local tbl = require '@utils/tbl'

local base = require './base'

-- defs
export type universe_data = {
	private_server_price: number?,
	voice_chat: boolean?,

	-- develop universe_configuration fields
	is_for_sale: boolean?,
	price: number?,
	allow_private_servers: boolean?,
	genre: 'All' | 'Restricted' | string?,
	is_friends_only: boolean?,
	is_archived: boolean?,
	studio_access_to_apis_allowed: boolean?,
	is_mesh_texture_api_access_allowed: boolean?,

	-- socials
	facebook: social_link?,
	twitter: social_link?,
	youtube: social_link?,
	twitch: social_link?,
	discord: social_link?,
	roblox_group: social_link?,
	guilded: social_link?,

	-- devices
	desktop: boolean?,
	mobile: boolean?,
	tablet: boolean?,
	console: boolean?,
	vr: boolean?,
}
export type universe_input = universe_data & {
	conflicts: { [string]: any },
}
export type universe_lock = {
	universe_id: number,
	input: universe_data,
}

export type social_link = { title: string?, uri: string? }

-- validation
local DEVICE_FIELDS: { [string]: true } = { desktop = true, mobile = true, tablet = true, console = true, vr = true }
local SOCIAL_FIELDS: { [string]: true } = {
	facebook = true,
	twitter = true,
	youtube = true,
	twitch = true,
	discord = true,
	roblox_group = true,
	guilded = true,
}

local function validate_social(link: any, label: string)
	base.req(link, 'table', label)
	base.opt(link.title, 'string', `{label}.title`)
	base.opt(link.uri, 'string', `{label}.uri`)
end
local function validate_bool(v, l)
	base.req(v, 'boolean', l)
end

local function validate_input(u: universe_input, label: string)
	base.req(u, 'table', label)

	base.flatten_group(u, 'socials', SOCIAL_FIELDS, validate_social, label)
	base.flatten_group(u, 'devices', DEVICE_FIELDS, validate_bool, label)

	base.opt(u.voice_chat, 'boolean', `{label}.voice_chat`)
	base.opt(u.private_server_price, 'number', `{label}.private_server_price`)

	-- develop universe_configuration fields
	base.opt(u.is_for_sale, 'boolean', `{label}.is_for_sale`)
	base.opt(u.price, 'number', `{label}.price`)
	base.opt(u.allow_private_servers, 'boolean', `{label}.allow_private_servers`)
	base.opt(u.genre, 'string', `{label}.genre`)
	base.opt(u.is_friends_only, 'boolean', `{label}.is_friends_only`)
	base.opt(u.is_archived, 'boolean', `{label}.is_archived`)
	base.opt(u.studio_access_to_apis_allowed, 'boolean', `{label}.studio_access_to_apis_allowed`)
	base.opt(u.is_mesh_texture_api_access_allowed, 'boolean', `{label}.is_mesh_texture_api_access_allowed`)

	base.opt(u.conflicts, 'table', `{label}.conflicts`)
	u.conflicts = u.conflicts or {}
end

local function validate_lock(entry: universe_lock, label: string)
	base.req(entry.universe_id, 'number', `{label}.universe_id`)

	validate_input(entry.input :: any, `{label}.input`);
	(entry :: any).input.conflicts = nil
end

-- encoding
local function encode_input(u: universe_input): universe_input
	local socials = tbl.intersection(u, SOCIAL_FIELDS)
	local devices = tbl.intersection(u, DEVICE_FIELDS)

	local out = tbl.subtraction(u, {
		conflicts = next(u.conflicts) == nil or nil,
	})
	tbl.subtract(out, SOCIAL_FIELDS)
	tbl.subtract(out, DEVICE_FIELDS)

	return tbl.applied(out, {
		socials = if next(socials) ~= nil then socials else nil,
		devices = if next(devices) ~= nil then devices else nil,
	})
end

-- diff
local function diff(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	local out = base.diff_fields(from, to, {
		'is_friends_only',
		'private_server_price',
		'voice_chat',

		'desktop',
		'mobile',
		'tablet',
		'console',
		'vr',

		-- develop universe_configuration fields
		'is_for_sale',
		'price',
		'allow_private_servers',
		'genre',
		'is_archived',
		'studio_access_to_apis_allowed',
		'is_mesh_texture_api_access_allowed',
	})

	for field in SOCIAL_FIELDS do
		if to[field] ~= nil and base.json_of(from[field]) ~= base.json_of(to[field]) then out[field] = to[field] end
	end

	return out
end

local function mask(read: universe_data, input: universe_input): universe_input
	local out: any = diff(read, input)
	out.conflicts = input.conflicts or {}

	return out
end

-- api impl
local function from_universe_api(data: cloud.universe): universe_data
	return {
		private_server_price = data.privateServerPriceRobux,
		voice_chat = data.voiceChatEnabled,

		desktop = data.desktopEnabled,
		mobile = data.mobileEnabled,
		tablet = data.tabletEnabled,
		console = data.consoleEnabled,
		vr = data.vrEnabled,

		facebook = data.facebookSocialLink,
		twitter = data.twitterSocialLink,
		youtube = data.youtubeSocialLink,
		twitch = data.twitchSocialLink,
		discord = data.discordSocialLink,
		roblox_group = data.robloxGroupSocialLink,
		guilded = data.guildedSocialLink,
	}
end

local function from_universe_config(data: cloud.universe_configuration_data): universe_data
	local any: any = data
	return {
		is_for_sale = data.isForSale,
		price = data.price,
		allow_private_servers = data.allowPrivateServers,
		is_friends_only = data.isFriendsOnly,
		is_archived = data.isArchived,
		is_mesh_texture_api_access_allowed = data.isMeshTextureApiAccessAllowed,
		-- genre = data.genre,

		-- GET exposes studio access as `isStudioAccessToApisAllowed`; the PATCH echo uses `studioAccessToApisAllowed`
		studio_access_to_apis_allowed = if any.isStudioAccessToApisAllowed ~= nil
			then any.isStudioAccessToApisAllowed
			else any.studioAccessToApisAllowed,
	}
end

local function to_universe_params(patch: universe_input): cloud.universe
	return {
		privateServerPriceRobux = patch.private_server_price,

		voiceChatEnabled = patch.voice_chat,
		desktopEnabled = patch.desktop,
		mobileEnabled = patch.mobile,
		tabletEnabled = patch.tablet,
		consoleEnabled = patch.console,
		vrEnabled = patch.vr,

		facebookSocialLink = patch.facebook,
		twitterSocialLink = patch.twitter,
		youtubeSocialLink = patch.youtube,
		twitchSocialLink = patch.twitch,
		discordSocialLink = patch.discord,
		robloxGroupSocialLink = patch.roblox_group,
		guildedSocialLink = patch.guilded,
	} :: any -- weird cloud type
end

local function to_universe_config_params(patch: universe_input): cloud.universe_settings_patch
	return {
		isForSale = patch.is_for_sale,
		price = patch.price,
		allowPrivateServers = patch.allow_private_servers,
		isArchived = patch.is_archived,
		isMeshTextureApiAccessAllowed = patch.is_mesh_texture_api_access_allowed,
		studioAccessToApisAllowed = patch.studio_access_to_apis_allowed,
		isFriendsOnly = patch.is_friends_only,
		-- genre = patch.genre,
	}
end

local function build_universe_api(session: cloud.apikey_session, user_session: cloud.cookie_session)
	local function update(u: cloud.universe_identity, patch: universe_input): universe_data
		local applied: { [string]: any } = {}

		local open_params = to_universe_params(patch)
		pcall(function()
			if next(open_params) == nil then return end

			local res = http.request('PATCH', `universe/{u.universe_id}`, function()
				return cloud.universe.update(session, u, open_params)
			end)
			tbl.apply(applied, from_universe_api(res))
		end)

		local config_params = to_universe_config_params(patch)
		pcall(function()
			if next(config_params) == nil then return end

			local res = http.request('PATCH', `universes/{u.universe_id}/configuration`, function()
				return cloud.universe_configuration.update(user_session, u, config_params)
			end)
			tbl.apply(applied, from_universe_config(res))
		end)

		return applied
	end
	local function get(u: cloud.universe_identity): universe_data
		local open = from_universe_api(http.request('GET', `universe/{u.universe_id}`, function()
			return cloud.universe.get(session, u)
		end))
		local config = from_universe_config(http.request('GET', `universes/{u.universe_id}/configuration`, function()
			return cloud.universe_configuration.get(user_session, u)
		end))

		return tbl.apply(open, config)
	end
	return { get = get, update = update }
end

export type api = typeof(build_universe_api(_G, _G))

-- module
return table.freeze {
	validate_input = validate_input,
	validate_lock = validate_lock,

	encode_input = encode_input,

	diff = diff,
	mask = mask,

	SOCIAL_FIELDS = SOCIAL_FIELDS,
	DEVICE_FIELDS = DEVICE_FIELDS,

	from_universe_api = from_universe_api,
	to_universe_params = to_universe_params,
	from_universe_config = from_universe_config,
	to_universe_config_params = to_universe_config_params,
	build_universe_api = build_universe_api,
}
