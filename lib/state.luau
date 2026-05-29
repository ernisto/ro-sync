local serde = require '@lune/serde'
local tbl = require '@utils/tbl'

-- types
export type owner = { user: nil, group: number } | { user: number, group: nil }
export type file_input = { hash: string, content: buffer, assetid: nil }
export type file_lock = { hash: string?, content: nil, assetid: number }
export type file = file_input | file_lock

-- a content-hashed asset with no roblox assetid (e.g. an uploaded place file)
export type place_file = { hash: string, content: buffer? }

export type social_link = { title: string?, uri: string? }

export type manifest = {
	owner: owner,
	products: { [string]: product_input },
	places: { [string]: place_input }?,
	universe: universe_input?,
}
export type lock = {
	universe_id: number?,
	products: { [string]: product_lock },
	places: { [string]: place_lock }?,
	universe: universe_lock?,
}

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

export type place_input = {
	file: string?,
	file_asset: place_file?,
	display_name: string?,
	description: string?,
	server_size: number?,
	conflicts: { [string]: any },
}
export type place_lock = {
	universe_id: number,
	place_id: number,
	input: place_input,
}

export type universe_input = {
	facebook: social_link?,
	twitter: social_link?,
	youtube: social_link?,
	twitch: social_link?,
	discord: social_link?,
	roblox_group: social_link?,
	guilded: social_link?,
	voice_chat: boolean?,
	desktop: boolean?,
	mobile: boolean?,
	tablet: boolean?,
	console: boolean?,
	vr: boolean?,
	private_server_price: number?,
	conflicts: { [string]: any },
}
export type universe_lock = {
	universe_id: number,
	input: universe_input,
}

export type product = { key: string, lock: product_lock?, input: product_input }
export type place = { key: string, lock: place_lock?, input: place_input }
export type universe = { key: string, lock: universe_lock?, input: universe_input }
export type resources = {
	products: { product },
	places: { place },
	universe: universe?,
	manifest: manifest,
	lock: lock,
}

-- diff masks
-- `complex` maps a field whose normalized (comparable) form differs from its real value;
-- the scalarize fn produces the comparable form, the real value is restored after diffing.
local function hash_of(f: any): any
	return f.hash
end
local function json_of(v: any): any
	return serde.encode('json', v)
end

local PRODUCT_MASK = {
	name = '',
	icon_file = {} :: file,
	price = 0,
	description = '',
	is_for_sale = true,
	regional_pricing = true,
	store_page_enabled = true,
}
local PRODUCT_COMPLEX = { icon_file = hash_of }

local PLACE_MASK = { file_asset = {} :: place_file, display_name = '', description = '', server_size = 0 }
local PLACE_COMPLEX = { file_asset = hash_of }

local SOCIAL_FIELDS = { 'facebook', 'twitter', 'youtube', 'twitch', 'discord', 'roblox_group', 'guilded' }
local UNIVERSE_MASK: { [string]: any } = {
	voice_chat = true,
	desktop = true,
	mobile = true,
	tablet = true,
	console = true,
	vr = true,
	private_server_price = 0,
}
local UNIVERSE_COMPLEX: { [string]: (any) -> any } = {}
for _, field in SOCIAL_FIELDS do
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

local diff_product = make_diff(PRODUCT_MASK, PRODUCT_COMPLEX)
local diff_place = make_diff(PLACE_MASK, PLACE_COMPLEX)
local diff_universe = make_diff(UNIVERSE_MASK, UNIVERSE_COMPLEX)

local function parse_manifest(content: buffer): manifest
	local data = serde.decode('yaml', content)
	assert(data.version == 1, `unsupported version {data.version}`)

	local products = data.products or {}
	assert(type(products) == 'table')
	for key, product in products do
		assert(type(product) == 'table')
		assert(type(key) == 'string')
		product.conflicts = product.conflicts or {}
	end
	data.products = products

	local places = data.places or {}
	assert(type(places) == 'table')
	for key, place in places do
		assert(type(place) == 'table')
		assert(type(key) == 'string')
		place.conflicts = place.conflicts or {}
	end
	data.places = places

	if data.universe then
		assert(type(data.universe) == 'table')
		data.universe.conflicts = data.universe.conflicts or {}
	end

	return data
end
local function parse_lock(content: buffer): lock
	local data = serde.decode('yaml', content)
	assert(data.version == 1, `unsupported version {data.version}`)

	local products = data.products or {}
	assert(type(products) == 'table')
	for key, product in products do
		assert(type(key) == 'string')
		assert(type(product) == 'table')
	end
	data.products = products

	local places = data.places or {}
	assert(type(places) == 'table')
	for key, place in places do
		assert(type(key) == 'string')
		assert(type(place) == 'table')
	end
	data.places = places

	if data.universe then assert(type(data.universe) == 'table') end

	return data
end

local function encode_manifest(data: manifest): string
	local out: any = tbl.applied(data, { version = 1, products = {}, places = {} })
	for k, product in data.products do
		out.products[k] = table.clone(product)
		out.products[k].icon_file = nil
		if product.addons and next(product.addons) == nil then out.products[k] = nil end
		if next(product.conflicts) == nil then out.products[k].conflicts = nil end
	end
	local places: { [string]: place_input } = data.places or {}
	for k, place in places do
		out.places[k] = table.clone(place)
		out.places[k].file_asset = nil
		if next(place.conflicts) == nil then out.places[k].conflicts = nil end
	end
	if next(out.places) == nil then out.places = nil end
	if data.universe then
		out.universe = table.clone(data.universe)
		if next(data.universe.conflicts) == nil then out.universe.conflicts = nil end
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
	local places: { [string]: place_lock } = data.places or {}
	for k, place in places do
		local input = place.input
		local file_asset = input and input.file_asset
		local clean_file = file_asset and tbl.intersection(file_asset, { hash = '' })
		out.places[k] = tbl.applied(place, { input = tbl.applied(input, { file_asset = clean_file }) })
	end
	if next(out.places) == nil then out.places = nil end
	return serde.encode('yaml', out, true)
end

local function build_resources(inputs: manifest, locks: lock): resources
	local products = {}
	for key, input in inputs.products do
		table.insert(products, { key = key, input = input, lock = locks.products[key] })
	end

	local input_places: { [string]: place_input } = inputs.places or {}
	local lock_places: { [string]: place_lock } = locks.places or {}
	local places = {}

	for key, input in input_places do
		table.insert(places, { key = key, input = input, lock = lock_places[key] })
	end

	local universe = if inputs.universe
		then { key = 'universe', input = inputs.universe, lock = locks.universe }
		else nil

	return { products = products, places = places, universe = universe, manifest = inputs, lock = locks }
end

-- module
return table.freeze {
	parse_manifest = parse_manifest,
	parse_lock = parse_lock,
	encode_manifest = encode_manifest,
	encode_lock = encode_lock,
	build_resources = build_resources,

	diff_product = diff_product,
	diff_place = diff_place,
	diff_universe = diff_universe,
}
