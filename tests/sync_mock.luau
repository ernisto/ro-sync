local sync = require '@lib/sync'
local tbl = require '@utils/tbl'

-- constants
local UNIVERSE_ID = 1000
local PRODUCT_ID = 2000
local ICON_ID = 3000
local PLACE_ID = 4000

local DEFAULT_OPTS: sync.sync_opts = { universe_id = UNIVERSE_ID, force_fresh_state = false }

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

-- mirrors a product_input as a flat_product (simulates cloud returning unchanged state)
local function cloud_mirror(input: any): any
	local icon_id = type(input.icon) == 'table' and input.icon.assetid or nil
	return {
		universe_id = UNIVERSE_ID,
		product_id = PRODUCT_ID,
		icon = if icon_id then { assetid = icon_id } else nil,
		name = input.name,
		price = input.price,
		description = input.description,
		is_for_sale = input.is_for_sale,
		regional_pricing = input.regional_pricing,
		store_page_enabled = input.store_page_enabled,
	}
end

-- a full product_read (product_data + identity) as the cloud would return from create/get
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
-- place configuration returns settings only — never the file
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

	make_place_input = make_place_input,
	make_place_lock = make_place_lock,
	make_place = make_place,
	make_asset_file = make_asset_file,
	place_mirror = place_mirror,

	make_universe_input = make_universe_input,
	make_universe_lock = make_universe_lock,
	make_universe = make_universe,
	universe_mirror = universe_mirror,
}
