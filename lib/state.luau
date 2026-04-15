local serde = require '@lune/serde'
local tbl = require '@utils/tbl'

-- types
type owner = { user: nil, group: number } | { user: number, group: nil }
export type file_input = { hash: string, content: buffer, assetid: nil }
export type file_lock = { hash: string?, content: nil, assetid: number }
export type file = file_input | file_lock

export type manifest = { owner: owner, products: { [string]: product_input } }
export type lock = { universe_id: number?, products: { [string]: product_lock } }

export type product_input = {
	name: string,
	icon: string?,
	icon_file: file?,
	price: number?,
	description: string?,
	is_for_sale: boolean?,
	regional_pricing: boolean?,
	store_page_enabled: boolean?,
	conflicts: { [string]: any },
	addons: { [string]: any }?,
}
export type product_lock = {
	universe_id: number,
	product_id: number,
	input: product_input,
}

export type product = { key: string, lock: product_lock?, input: product_input }
export type resources = {
	products: { product },
	manifest: manifest,
	lock: lock,
}

-- constants
local DIFF_PRODUCT_MASK = {
	name = '',
	icon_file = {} :: file,
	price = 0,
	description = '',
	is_for_sale = true,
	regional_pricing = true,
	store_page_enabled = true,
}

-- functions
local function normalize(source: { [string]: any }): { [string]: any }
	local result = tbl.intersection(source, DIFF_PRODUCT_MASK)
	if type(result.icon_file) == 'table' then result.icon_file = result.icon_file.hash :: any end
	return result
end
local function diff_product(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	local changes = tbl.changes(normalize(from), normalize(to))
	if changes.icon_file ~= nil then changes.icon_file = to.icon_file end
	return changes
end

local function parse_manifest(content: buffer): manifest
	local data = serde.decode('yaml', content)
	assert(data.version == 1, `unsupported version {data.version}`)
	assert(type(data.products) == 'table')

	for key, product in data.products do
		assert(type(product) == 'table')
		assert(type(key) == 'string')
		product.conflicts = product.conflicts or {}
	end
	return data
end
local function parse_lock(content: buffer): lock
	local data = serde.decode('yaml', content)
	assert(data.version == 1, `unsupported version {data.version}`)
	assert(type(data.products) == 'table')

	for key, product in data.products do
		assert(type(key) == 'string')
		assert(type(product) == 'table')
	end
	return data
end

local function encode_manifest(data: manifest): string
	local out: any = tbl.applied(data, { version = 1, products = {} })
	for k, product in data.products do
		out.products[k] = table.clone(product)

		out.products[k].icon_file = nil
		if product.addons and next(product.addons) == nil then out.products[k] = nil end
		if next(product.conflicts) == nil then out.products[k].conflicts = nil end
	end
	return serde.encode('yaml', out, true)
end
local function encode_lock(data: lock): string
	local out = tbl.applied(data, { version = 1, products = {} })
	for k, product in data.products do
		local input = product.input
		local icon_file = input and input.icon_file

		local clean_icon = icon_file and tbl.intersection(icon_file, { assetid = 0, hash = '' })
		out.products[k] = tbl.applied(product, { input = tbl.applied(input, { icon_file = clean_icon }) })
	end
	return serde.encode('yaml', out, true)
end

local function build_resources(inputs: manifest, locks: lock): resources
	local products = {}
	for key, input in inputs.products do
		table.insert(products, { key = key, input = input, lock = locks.products[key] })
	end
	return { products = products, manifest = inputs, lock = locks }
end

-- module
return table.freeze {
	parse_manifest = parse_manifest,
	parse_lock = parse_lock,
	encode_manifest = encode_manifest,
	encode_lock = encode_lock,
	build_resources = build_resources,
	diff_product = diff_product,
}
