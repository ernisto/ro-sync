local cloud = require '@pkg/ro_cloud'
local http = require '@utils/http'
local tbl = require '@utils/tbl'

local base = require './base'
local universe_configuration = require './universe_configuration'

-- defs
export type social_link = { title: string?, uri: string? }
export type universe_data = {
	private_server_price: number?,
	voice_chat: boolean?,

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
	configuration: universe_configuration.universe_configuration_input?,
	conflicts: { [string]: any },
}
export type universe_lock = {
	universe_id: number,
	input: universe_data,
	configuration: universe_configuration.universe_configuration_lock?,
}

local LINK: base.field_map = { title = { 'title', 'string' }, uri = { 'uri', 'string' } }

-- open cloud universe fields
local FIELDS: base.field_map = {
	private_server_price = { 'privateServerPriceRobux', 'number' },
	voice_chat = { 'voiceChatEnabled', 'boolean' },

	desktop = { 'desktopEnabled', 'boolean' },
	mobile = { 'mobileEnabled', 'boolean' },
	tablet = { 'tabletEnabled', 'boolean' },
	console = { 'consoleEnabled', 'boolean' },
	vr = { 'vrEnabled', 'boolean' },

	facebook = { 'facebookSocialLink', 'table', LINK },
	twitter = { 'twitterSocialLink', 'table', LINK },
	youtube = { 'youtubeSocialLink', 'table', LINK },
	twitch = { 'twitchSocialLink', 'table', LINK },
	discord = { 'discordSocialLink', 'table', LINK },
	roblox_group = { 'robloxGroupSocialLink', 'table', LINK },
	guilded = { 'guildedSocialLink', 'table', LINK },
}

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

-- validation
local function parse_input(u: any, label: string)
	base.req(u, 'table', label)

	base.flatten_group(u, 'socials', SOCIAL_FIELDS, label)
	base.flatten_group(u, 'devices', DEVICE_FIELDS, label)
	base.validate_map(u, FIELDS, label)

	if u.configuration ~= nil then universe_configuration.parse_input(u.configuration, `{label}.configuration`) end

	base.opt(u.conflicts, 'table', `{label}.conflicts`)
	u.conflicts = u.conflicts or {}
end

local function parse_lock(entry: any, label: string)
	base.req(entry.universe_id, 'number', `{label}.universe_id`)

	parse_input(entry.input, `{label}.input`)
	entry.input.conflicts = nil

	if entry.configuration ~= nil then
		universe_configuration.parse_lock(entry.configuration, `{label}.configuration`)
	end
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
		configuration = u.configuration and universe_configuration.encode_input(u.configuration),
	})
end

-- diff
local function diff(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	return base.diff_map(from, to, FIELDS)
end

-- api impl
type session = base.session
type universe_path = { universe_id: number }

local function update(session: session, game: universe_path, patch: universe_input): (universe_data, string?)
	local path = { universe_id = game.universe_id }
	return base.from_api(FIELDS, http.call(cloud.universe.update, session, path, base.to_api(FIELDS, patch)))
end

local function get(session: session, game: universe_path): universe_data
	local path = { universe_id = game.universe_id }
	return base.from_api(FIELDS, http.call(cloud.universe.get, session, path, nil))
end

-- module
return table.freeze {
	FIELDS = FIELDS,
	SOCIAL_FIELDS = SOCIAL_FIELDS,
	DEVICE_FIELDS = DEVICE_FIELDS,

	parse_input = parse_input,
	parse_lock = parse_lock,

	encode_input = encode_input,

	diff = diff,
	mask = base.mask,

	stage = base.stage,

	get = get,
	update = update,
	create = base.unsupported 'universes cant be created through open cloud, create one in studio or creator hub',
	list = base.unsupported 'universes cant be listed through open cloud',
	delete = base.unsupported 'universes cant be deleted through open cloud',
}
