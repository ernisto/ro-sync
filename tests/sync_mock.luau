local mock = require '@test/mock'
local product_res = require '@lib/resources/product'
local sync = require '@lib/sync'
local tbl = require '@utils/tbl'

-- constants
local UNIVERSE_ID = 1000
local PRODUCT_ID = 2000
local ICON_ID = 3000
local PLACE_ID = 4000

local DEFAULT_OPTS: sync.sync_opts =
	{ universe_id = UNIVERSE_ID, session = { api_key_state = { key = 'key' }, cookie_state = { cookie = 'cookie' } } }

-- product builders
local function make_input(overrides: { [string]: any }?): any
	local base = { name = 'Pack', price = 100, description = 'A pack', is_for_sale = true, conflicts = {} }
	if overrides then
		for k, v in overrides do
			base[k] = v
		end
	end
	return base
end

local function make_lock(input: any): any
	return { universe_id = UNIVERSE_ID, product_id = PRODUCT_ID, input = input }
end

local function make_product(input: any, lock: any?): any
	return { key = 'key', input = input, lock = lock }
end

-- icon builders
local function make_icon_input(hash: string): any
	return { hash = hash, content = buffer.create(0) }
end

local function make_icon_lock(assetid: number, hash: string?): any
	return { assetid = assetid, hash = hash }
end

local function cloud_mirror(input: any): product_res.product_read
	local icon_id = type(input.icon) == 'table' and input.icon.assetid or nil
	return {
		universe_id = UNIVERSE_ID,
		product_id = PRODUCT_ID,
		icon_file = { assetid = if icon_id then icon_id else -1 },
		name = input.name,
		price = input.price,
		description = input.description,
		is_for_sale = input.is_for_sale,
		regional_pricing = input.regional_pricing,
		store_page_enabled = input.store_page_enabled,
	}
end

local function make_product_read(overrides: { [string]: any }): any
	return tbl.apply({
		universe_id = UNIVERSE_ID,
		product_id = PRODUCT_ID,
		name = 'Pack',
		price = 100,
		description = 'A pack',
		is_for_sale = true,
		regional_pricing = false,
		store_page_enabled = false,
	}, overrides)
end

-- update echoes: mirror what the real apis return from `update` (only the applied fields)

local function product_echo(_prev: any, patch: any): any
	local out: any = {}
	for _, field in { 'name', 'price', 'description', 'is_for_sale', 'regional_pricing', 'store_page_enabled' } do
		if patch[field] ~= nil then out[field] = patch[field] end
	end
	if patch.icon_file then out.icon_file = { hash = patch.icon_file.hash, assetid = ICON_ID } end
	return out
end

-- place builders
local function make_place_input(overrides: { [string]: any }?): any
	return tbl.apply(
		{ display_name = 'Start', description = 'A place', server_size = 50, conflicts = {} },
		overrides or {}
	)
end
local function make_place_lock(input: any): any
	return { universe_id = UNIVERSE_ID, place_id = PLACE_ID, input = input }
end
local function make_place(input: any, lock: any?): any
	return { key = 'place', input = input, lock = lock }
end
local function make_asset_file(hash: string): any
	return { hash = hash, content = buffer.create(0) }
end
local function place_mirror(input: any): any
	return {
		display_name = input.display_name,
		description = input.description,
		server_size = input.server_size,
		social_slot_type = input.social_slot_type,
		custom_social_slots_count = input.custom_social_slots_count,
		allow_copying = input.allow_copying,
		allowed_gear_types = input.allowed_gear_types,
		is_all_genres_allowed = input.is_all_genres_allowed,
	}
end
local function place_echo(_prev: any, patch: any): any
	local out: any = {}
	for _, field in
		{
			'display_name',
			'description',
			'server_size',
			'social_slot_type',
			'custom_social_slots_count',
			'allow_copying',
			'is_all_genres_allowed',
		}
	do
		if patch[field] ~= nil then out[field] = patch[field] end
	end
	if patch.asset_file then out.asset_file = { hash = patch.asset_file.hash, assetid = PLACE_ID } end
	return out
end

-- universe builders
local function make_universe_input(overrides: { [string]: any }?): any
	return tbl.apply({ desktop = true, mobile = true, private_server_price = 0, conflicts = {} }, overrides or {})
end
local function make_universe_lock(input: any): any
	return { universe_id = UNIVERSE_ID, input = input }
end
local function make_universe(input: any, lock: any?): any
	return { key = 'universe', input = input, lock = lock }
end
local function universe_mirror(input: any): any
	local out = table.clone(input)
	out.conflicts = nil
	return out
end
local function universe_echo(_prev: any, patch: any): any
	local out = table.clone(patch)
	out.conflicts = nil
	return out
end

-- mock api builders: `get` returns the initial cloud state and `update` applies
-- the patch onto that same state (like the real cloud) before returning the result.
-- `never` lists api members that must not be called by the sync.
local function make_api(cloud: { [string]: any }, echo: (any, any) -> any, never: { string }?): any
	local api: any = {
		get = mock.fn(function()
			return table.clone(cloud)
		end),
		update = mock.fn(function(_, _, patch)
			return tbl.applied(table.clone(cloud), echo(nil, patch))
		end),
	}
	local skip: { string } = never or {}
	for _, name in skip do
		api[name] = mock.never_called(`{name} should not be called`)
	end
	return api
end

local function make_product_api(cloud_input: { [string]: any }?, never: { string }?): any
	return make_api(cloud_mirror(make_input(cloud_input)), product_echo, never)
end

local function make_place_api(cloud_input: { [string]: any }?, never: { string }?): any
	return make_api(place_mirror(make_place_input(cloud_input)), place_echo, never)
end

local function make_universe_api(cloud_input: { [string]: any }?, never: { string }?): any
	return make_api(universe_mirror(make_universe_input(cloud_input)), universe_echo, never)
end

-- module
return table.freeze {
	UNIVERSE_ID = UNIVERSE_ID,
	PRODUCT_ID = PRODUCT_ID,
	ICON_ID = ICON_ID,
	PLACE_ID = PLACE_ID,
	DEFAULT_OPTS = DEFAULT_OPTS,

	make_input = make_input,
	make_lock = make_lock,
	make_product = make_product,
	make_icon_input = make_icon_input,
	make_icon_lock = make_icon_lock,
	make_product_read = make_product_read,
	cloud_mirror = cloud_mirror,
	product_echo = product_echo,
	make_api = make_api,
	make_product_api = make_product_api,
	make_place_api = make_place_api,
	make_universe_api = make_universe_api,

	make_place_input = make_place_input,
	make_place_lock = make_place_lock,
	make_place = make_place,
	make_asset_file = make_asset_file,
	place_mirror = place_mirror,
	place_echo = place_echo,

	make_universe_input = make_universe_input,
	make_universe_lock = make_universe_lock,
	make_universe = make_universe,
	universe_mirror = universe_mirror,
	universe_echo = universe_echo,
}
