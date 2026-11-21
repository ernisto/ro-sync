local cloud = require '@pkg/ro_cloud'
local http = require '@utils/http'
local tbl = require '@utils/tbl'

local base = require './base'

-- defs
export type universe_configuration_input = { [string]: any, conflicts: { [string]: any } }
export type universe_configuration_lock = { universe_id: number, input: { [string]: any } }

local SCALES: base.field_map = {
	height = { 'height', 'number' },
	width = { 'width', 'number' },
	head = { 'head', 'number' },
	depth = { 'depth', 'number' },
	proportion = { 'proportion', 'number' },
	body_type = { 'bodyType', 'number' },
}
-- Enum.AssetType ids overridable in avatar settings; other ids round-trip as `asset_type_<id>`
local ASSET_TYPES: { [string]: number } = {
	t_shirt = 2,
	shirt = 11,
	pants = 12,
	head = 17,
	face = 18,
	torso = 27,
	right_arm = 28,
	left_arm = 29,
	left_leg = 30,
	right_leg = 31,
}
local ASSET_TYPE_NAMES: { [number]: string } = {}
for name, id in ASSET_TYPES do
	ASSET_TYPE_NAMES[id] = name
end
local PERMISSIONS: base.field_map = {
	third_party_teleport_allowed = { 'IsThirdPartyTeleportAllowed', 'boolean' },
	third_party_asset_allowed = { 'IsThirdPartyAssetAllowed', 'boolean' },
	third_party_purchase_allowed = { 'IsThirdPartyPurchaseAllowed', 'boolean' },
	client_teleport_allowed = { 'IsClientTeleportAllowed', 'boolean' },
}

-- develop api fields; private server price and devices are synced by the universe itself (open cloud)
local FIELDS: base.field_map = {
	name = { 'name', 'string' },
	description = { 'description', 'string' },
	genre = { 'genre', 'number' },
	promotional_text = { 'promotionalText', 'string' },
	allow_private_servers = { 'allowPrivateServers', 'boolean' },
	permissions = { 'permissions', 'table', PERMISSIONS },
	fiat_base_price_id = { 'fiatBasePriceId', 'string' },
	fiat_product_change_type = { 'fiatProductChangeType', 'number' },

	-- playability
	price = { 'price', 'number' },
	is_for_sale = { 'isForSale', 'boolean' },
	is_archived = { 'isArchived', 'boolean' },
	is_friends_only = { 'isFriendsOnly', 'boolean' },
	audiences = { 'audiences', 'table' },
	demo_mode_enabled = { 'demoModeEnabled', 'boolean' },

	-- avatar
	engine_avatar_settings = { 'engineAvatarSettings', 'string' },
	avatar_type = { 'universeAvatarType', 'number' },
	animation_type = { 'universeAnimationType', 'number' },
	collision_type = { 'universeCollisionType', 'number' },
	joint_positioning_type = { 'universeJointPositioningType', 'number' },
	avatar_asset_overrides = { 'universeAvatarAssetOverrides', 'table' }, -- { [type name]: override }, see below
	avatar_min_scales = { 'universeAvatarMinScales', 'table', SCALES },
	avatar_max_scales = { 'universeAvatarMaxScales', 'table', SCALES },

	-- permissions
	is_mesh_texture_api_access_allowed = { 'isMeshTextureApiAccessAllowed', 'boolean' },
	is_rewarded_on_demand_ads_allowed = { 'isRewardedOnDemandAdsAllowed', 'boolean' },
	studio_access_to_apis_allowed = { 'studioAccessToApisAllowed', 'boolean' },

	-- ponytail: opt_in/opt_out_regions skipped, PATCH takes ids but echoes { region, status }; map when needed
}

-- avatar asset overrides: manifest `{ [type name]: { asset_id, player_choice } }` <-> api list
local function asset_type_id(name: string): number?
	return ASSET_TYPES[name] or tonumber(string.match(name, '^asset_type_(%d+)$'))
end

local function overrides_from_api(list: { any }?): { [string]: any }?
	if not list then return nil end

	local out = {}
	for _, o in list do
		out[ASSET_TYPE_NAMES[o.assetTypeID] or `asset_type_{o.assetTypeID}`] =
			{ asset_id = o.assetID, player_choice = o.isPlayerChoice }
	end
	return out
end

local function overrides_to_api(map: { [string]: any }): { any }
	local out = {}
	for name, o in map do
		table.insert(
			out,
			{ assetID = o.asset_id, assetTypeID = asset_type_id(name), isPlayerChoice = o.player_choice == true }
		)
	end
	return out
end

local function validate_overrides(map: { [string]: any }?, label: string)
	if not map then return end

	for name, o in map do
		local entry = `{label}.{tostring(name)}`
		base.check(
			type(name) == 'string' and asset_type_id(name) ~= nil,
			`{entry}: unknown asset type, use one of t_shirt, shirt, pants, head, face, torso, right_arm, left_arm, left_leg, right_leg or asset_type_<id>`
		)
		base.req(o, 'table', entry)
		base.req(o.asset_id, 'number', `{entry}.asset_id`)
		base.opt(o.player_choice, 'boolean', `{entry}.player_choice`)
	end
end

-- validation
local function parse_input(c: any, label: string)
	base.parse_mapped(c, FIELDS, label)
	validate_overrides(c.avatar_asset_overrides, `{label}.avatar_asset_overrides`)
end

local function parse_lock(entry: any, label: string)
	base.req(entry, 'table', label)
	base.req(entry.universe_id, 'number', `{label}.universe_id`)

	parse_input(entry.input, `{label}.input`)
	entry.input.conflicts = nil
end

-- diff
local function diff(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	return base.diff_map(from, to, FIELDS)
end

-- api impl
type session = base.session
type universe_path = { universe_id: number }

local function from_api(data: any): { [string]: any }
	local out = base.from_api(FIELDS, data)
	-- GET exposes studio access as `isStudioAccessToApisAllowed`; the PATCH echo uses `studioAccessToApisAllowed`
	if data.isStudioAccessToApisAllowed ~= nil then
		out.studio_access_to_apis_allowed = data.isStudioAccessToApisAllowed
	end
	out.avatar_asset_overrides = overrides_from_api(out.avatar_asset_overrides)
	return out
end

local function to_api(patch: { [string]: any }): any
	local out = base.to_api(FIELDS, patch)
	if patch.avatar_asset_overrides then
		out.universeAvatarAssetOverrides = overrides_to_api(patch.avatar_asset_overrides)
	end
	return out
end

local function get(session: session, game: universe_path): { [string]: any }
	local path = { universe_id = game.universe_id }
	return from_api(http.call(cloud.universe_configuration.get, session, path, nil))
end

-- avatar/permission/description fields are write-only (never echoed): a 2xx confirms the patch for those
local function update(
	session: session,
	game: universe_path,
	patch: universe_configuration_input
): ({ [string]: any }, string?)
	local path = { universe_id = game.universe_id }
	local res = http.call(cloud.universe_configuration.update, session, path, to_api(patch))
	return tbl.applied(tbl.subtraction(patch, { conflicts = true }), from_api(res))
end

-- module
return table.freeze {
	FIELDS = FIELDS,

	parse_input = parse_input,
	parse_lock = parse_lock,
	encode_input = base.encode_mapped,

	diff = diff,
	mask = base.mask,

	get = get,
	update = update,
}
