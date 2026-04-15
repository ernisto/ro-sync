local sync = require '@lib/sync'

-- constants
local UNIVERSE_ID = 1000
local PRODUCT_ID = 2000
local ICON_ID = 3000

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
	local icon_id = type(input.icon) == 'table' and (input.icon :: any).assetid or nil
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

return table.freeze {
	UNIVERSE_ID = UNIVERSE_ID,
	PRODUCT_ID = PRODUCT_ID,
	ICON_ID = ICON_ID,
	DEFAULT_OPTS = DEFAULT_OPTS,

	make_input = make_input,
	make_lock = make_lock,
	make_product = make_product,
	make_icon_input = make_icon_input,
	make_icon_lock = make_icon_lock,
	cloud_mirror = cloud_mirror,
}
