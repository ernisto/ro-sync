local fs = require '@lune/fs'
local serde = require '@lune/serde'
local tbl = require '@utils/tbl'

-- types
export type manifest = { owner: owner, products: { [string]: product_input } }
type owner = { user: nil, group: number } | { user: number, group: nil }

export type product_input = {
	name: string,
	icon: string?,
	price: number?,
	description: string?,
	is_for_sale: boolean?,
	regional_pricing: boolean?,
	store_page_enabled: boolean?,
	conflicts: { [string]: any }?,
	[string]: any,
}

export type lock = { universe_id: number, products: { [string]: product_lock } }
export type product_lock = {
	universe_id: number,
	product_id: number,
	icon_id: number?,
	icon_hash: string?,
	input: product_input,
}

-- constants
local UNAVAILABLE_ID = -1
local PRODUCT_MASK =
	{ name = '', price = 0, description = '', is_for_sale = true, regional_pricing = true, store_page_enabled = true }

-- functions
local function pick_fields(source: { [string]: any }): typeof(PRODUCT_MASK)
	return tbl.intersection(source, PRODUCT_MASK)
end

local function read_inputs(path: string): manifest
	if not fs.isFile(path) then return { owner = { group = UNAVAILABLE_ID }, products = {} } end

	local out = serde.decode('yaml', fs.readFile(path))
	out.products = out.products or {}

	return out
end
local function read_lock(path: string): lock
	if not fs.isFile(path) then return { universe_id = UNAVAILABLE_ID, products = {} } end

	local out = serde.decode('yaml', fs.readFile(path))
	out.universe_id = out.universe_id or UNAVAILABLE_ID
	out.products = out.products or {}

	return out
end

-- module
return table.freeze {
	pick_fields = pick_fields,
	read_inputs = read_inputs,
	read_lock = read_lock,

	UNAVAILABLE_ID = UNAVAILABLE_ID,
	PRODUCT_FIELDS = PRODUCT_MASK,
}
