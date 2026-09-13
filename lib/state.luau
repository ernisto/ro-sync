local serde = require '@lune/serde'
local tbl = require '@utils/tbl'

local base = require '@lib/resources/base'
local place = require '@lib/resources/place'
local product = require '@lib/resources/product'
local universe = require '@lib/resources/universe'

-- types
export type owner = base.owner
export type lock_file = base.lock_file
export type input_file = base.input_file
export type social_link = universe.social_link

export type input = {
	owner: owner,
	universe: universe.universe_input?,
	places: { [string]: place.place_input },
	products: { [string]: product.product_input },
}
export type lock = {
	universe_id: number,
	universe: universe.universe_lock?,
	places: { [string]: place.place_lock },
	products: { [string]: product.product_lock },
}
export type manifest = input

export type product = { key: string, lock: product.product_lock?, input: product.product_input }
export type place = { key: string, lock: place.place_lock?, input: place.place_input }
export type universe = { key: string, lock: universe.universe_lock?, input: universe.universe_input }
export type resources = {
	products: { product },
	places: { place },
	universe: universe?,
	manifest: manifest,
	lock: lock,
}

-- constructors
local function create_input(owner: owner): manifest
	return { owner = owner, products = {}, places = {} }
end
local function create_state(universe_id: number): lock
	return { universe_id = universe_id, products = {}, places = {} }
end

-- parsing
local function parse_manifest(content: buffer): manifest
	local data = serde.decode('yaml', content)
	base.req(data, 'table', 'manifest')
	base.check(data.version == 1, `unsupported manifest version {tostring(data.version)}`)
	base.validate_owner(data.owner, 'manifest.owner')

	data.products = base.string_map(data.products, 'manifest.products')
	for key, entry in data.products do
		product.validate_input(entry, `manifest.products.{key}`)
	end

	data.places = base.string_map(data.places, 'manifest.places')
	for key, entry in data.places do
		place.validate_input(entry, `manifest.places.{key}`)
	end

	if data.universe ~= nil then universe.validate_input(data.universe, 'manifest.universe') end
	return data
end
local function parse_lock(content: buffer): lock
	local data = serde.decode('yaml', content)
	base.req(data, 'table', 'lock')
	base.check(data.version == 1, `unsupported lock version {tostring(data.version)}`)
	base.opt(data.universe_id, 'number', 'lock.universe_id')

	data.products = base.string_map(data.products, 'lock.products')
	for key, entry in data.products do
		product.validate_lock(entry, `lock.products.{key}`)
	end

	data.places = base.string_map(data.places, 'lock.places')
	for key, entry in data.places do
		place.validate_lock(entry, `lock.places.{key}`)
	end

	if data.universe ~= nil then
		base.req(data.universe, 'table', 'lock.universe')
		universe.validate_lock(data.universe, 'lock.universe')
	end

	return data
end

-- encoding
local function encode_manifest(data: manifest): string
	local out: any = tbl.applied(data, { version = 1, products = {}, places = {} })

	out.products = base.encode_map(data.products, product.encode_input)
	out.places = base.encode_map(data.places, place.encode_input)

	if data.universe then out.universe = universe.encode_input(data.universe) end

	return serde.encode('yaml', out, true)
end
local function encode_lock(data: lock): string
	local out: any = tbl.applied(data, { version = 1, products = {}, places = {} })

	out.products = base.encode_map(data.products, product.encode_lock_entry)
	out.places = base.encode_map(data.places, place.encode_lock_entry)

	return serde.encode('yaml', out, true)
end

-- resources
local function build_resources(inputs: manifest, locks: lock): resources
	local universe_entry = inputs.universe and { key = 'universe', input = inputs.universe, lock = locks.universe }

	local places = {}
	for key, input in inputs.places do
		table.insert(places, { key = key, input = input, lock = locks.places[key] })
	end

	local products = {}
	for key, input in inputs.products do
		table.insert(products, { key = key, input = input, lock = locks.products[key] })
	end

	return { products = products, places = places, universe = universe_entry, manifest = inputs, lock = locks }
end

-- module
return table.freeze {
	parse_manifest = parse_manifest,
	parse_lock = parse_lock,

	create_input = create_input,
	create_state = create_state,

	encode_manifest = encode_manifest,
	encode_lock = encode_lock,
	build_resources = build_resources,

	diff_product = product.diff,
	diff_place = place.diff,
	diff_universe = universe.diff,

	mask_product = product.mask,
	mask_place = place.mask,
	mask_universe = universe.mask,
}
