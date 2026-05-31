local serde = require '@lune/serde'
local tbl = require '@utils/tbl'

local parser = require './parser'
type file = parser.some_file
type place_file = parser.place_file
type social_link = parser.social_link

-- helpers
local function hash_of(f: any): any
	return f.hash
end
local function json_of(v: any): any
	return serde.encode('json', v)
end

-- defs
local PRODUCT_COMPLEX = { icon_file = hash_of }
local PRODUCT_MASK = {
	name = '',
	icon_file = {} :: file,
	price = 0,
	description = '',
	is_for_sale = true,
	regional_pricing = true,
	store_page_enabled = true,
}

local PLACE_COMPLEX = { asset_file = hash_of, allowed_gear_types = json_of }
local PLACE_MASK = {
	asset_file = {} :: place_file,
	display_name = '',
	description = '',
	server_size = 0,
	social_slot_type = '',
	custom_social_slots_count = 0,
	allow_copying = true,
	allowed_gear_types = {} :: { string },
	is_all_genres_allowed = true,
}

local UNIVERSE_MASK: { [string]: any } = {
	voice_chat = true,
	desktop = true,
	mobile = true,
	tablet = true,
	console = true,
	vr = true,
	private_server_price = 0,

	-- develop universe_configuration fields
	is_for_sale = true,
	price = 0,
	allow_private_servers = true,
	genre = '',
	is_friends_only = true,
	is_archived = true,
	studio_access_to_apis_allowed = true,
	is_mesh_texture_api_access_allowed = true,
}
local UNIVERSE_COMPLEX: { [string]: (any) -> any } = {}

for field in parser.SOCIAL_FIELDS do
	UNIVERSE_MASK[field] = {} :: social_link
	UNIVERSE_COMPLEX[field] = json_of
end

-- functions
local function make_diff(mask: { [string]: any }, complex: { [string]: (any) -> any })
	local function normalize(source: { [string]: any }): { [string]: any }
		local result = tbl.intersection(source, mask)
		for field, scalarize in complex do
			if type(result[field]) == 'table' then result[field] = scalarize(result[field]) end
		end
		return result
	end

	return function(from: { [string]: any }, to: { [string]: any }): { [string]: any }
		local changes = tbl.changes(normalize(from), normalize(to))
		for field in complex do
			if changes[field] ~= nil then changes[field] = to[field] end
		end
		return changes
	end
end

-- module
return table.freeze {
	diff_product = make_diff(PRODUCT_MASK, PRODUCT_COMPLEX),
	diff_place = make_diff(PLACE_MASK, PLACE_COMPLEX),
	diff_universe = make_diff(UNIVERSE_MASK, UNIVERSE_COMPLEX),
}
