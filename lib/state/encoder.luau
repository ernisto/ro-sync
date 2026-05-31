local serde = require '@lune/serde'
local tbl = require '@utils/tbl'

local parser = require './parser'
type manifest = parser.input
type lock = parser.lock

-- defs
export type product = { key: string, lock: parser.product_lock?, input: parser.product_input }
export type place = { key: string, lock: parser.place_lock?, input: parser.place_input }
export type universe = { key: string, lock: parser.universe_lock?, input: parser.universe_input }
export type resources = {
	products: { product },
	places: { place },
	universe: universe?,
	manifest: manifest,
	lock: lock,
}

-- functions
local function encode_manifest(data: manifest): string
	local out: any = tbl.applied(data, { version = 1, products = {}, places = {} })

	for k, product in data.products do
		out.products[k] = table.clone(product)
		out.products[k].icon_file = nil

		if product.addons and next(product.addons) == nil then out.products[k] = nil end
		if next(product.conflicts) == nil then out.products[k].conflicts = nil end
	end
	if next(out.products) == nil then out.products = nil end

	for k, place in data.places do
		out.places[k] = table.clone(place)
		out.places[k].asset_file = nil

		if next(place.conflicts) == nil then out.places[k].conflicts = nil end
	end
	if next(out.places) == nil then out.places = nil end

	if data.universe then
		out.universe = table.clone(data.universe)
		if next(data.universe.conflicts) == nil then out.universe.conflicts = nil end

		local socials = tbl.intersection(out.universe, parser.SOCIAL_FIELDS)
		tbl.subtract(out.universe, parser.SOCIAL_FIELDS)

		local devices = tbl.intersection(out.universe, parser.DEVICE_FIELDS)
		tbl.subtract(out.universe, parser.DEVICE_FIELDS)

		if next(socials) ~= nil then out.universe.socials = socials end
		if next(devices) ~= nil then out.universe.devices = devices end
	end

	return serde.encode('yaml', out, true)
end
local function encode_lock(data: lock): string
	local out: any = tbl.applied(data, { version = 1, products = {}, places = {} })

	for k, product in data.products do
		local input = product.input
		local icon_file = input and input.icon_file
		local clean_icon = icon_file and tbl.intersection(icon_file, { assetid = 0, hash = '' })

		out.products[k] = tbl.applied(product, { input = tbl.applied(input, { icon_file = clean_icon }) })
	end
	if next(out.products) == nil then out.products = nil end

	for k, place in data.places do
		local input = place.input
		local asset_file = input and input.asset_file
		local clean_file = asset_file and tbl.intersection(asset_file, { hash = '' })

		out.places[k] = tbl.applied(place, { input = tbl.applied(input, { asset_file = clean_file }) })
	end
	if next(out.places) == nil then out.places = nil end

	return serde.encode('yaml', out, true)
end

local function build_resources(inputs: manifest, locks: lock): resources
	local universe = inputs.universe and { key = 'universe', input = inputs.universe, lock = locks.universe }

	local places = {}
	for key, input in inputs.places do
		table.insert(places, { key = key, input = input, lock = locks.places[key] })
	end

	local products = {}
	for key, input in inputs.products do
		table.insert(products, { key = key, input = input, lock = locks.products[key] })
	end

	return { products = products, places = places, universe = universe, manifest = inputs, lock = locks }
end

-- module
return table.freeze {
	encode_manifest = encode_manifest,
	encode_lock = encode_lock,
	build_resources = build_resources,
}
