local serde = require '@lune/serde'
local tbl = require '@utils/tbl'

local base = require '@lib/resources/base'
local icon = require '@lib/resources/icon'
local pass = require '@lib/resources/pass'
local place = require '@lib/resources/place'
local product = require '@lib/resources/product'
local rekey = require '@lib/rekey'
local thumbnail = require '@lib/resources/thumbnail'
local universe = require '@lib/resources/universe'

-- types
export type owner = base.owner
export type lock_file = base.lock_file
export type input_file = base.input_file
export type social_link = universe.social_link

export type input = {
	owner: owner,
	universe: universe.universe_input?,
	passes: { [string]: pass.pass_input },
	places: { [string]: place.place_input },
	products: { [string]: product.product_input },
	thumbnails: { thumbnail.thumbnail_input }?, -- nil = unmanaged, rosync never deletes
	icon: icon.icon_input?,
}
export type lock = {
	universe_id: number,
	universe: universe.universe_lock?,
	passes: { [string]: pass.pass_lock },
	places: { [string]: place.place_lock },
	products: { [string]: product.product_lock },
	thumbnails: { [string]: thumbnail.thumbnail_lock }, -- keyed by image hash
	icon: icon.icon_lock?,
}
export type manifest = input

export type product = { key: string, lock: product.product_lock?, input: product.product_input }
export type pass = { key: string, lock: pass.pass_lock?, input: pass.pass_input }
export type thumbnail = { key: string, lock: thumbnail.thumbnail_lock?, input: thumbnail.thumbnail_input }
export type icon = { key: string, lock: icon.icon_lock?, input: icon.icon_input }
export type place = { key: string, lock: place.place_lock?, input: place.place_input }
export type universe = { key: string, lock: universe.universe_lock?, input: universe.universe_input }
export type resources = {
	thumbnails: { thumbnail },
	icon: icon?,
	products: { product },
	places: { place },
	passes: { pass },
	universe: universe?,
	manifest: manifest,
	lock: lock,
}

-- constructors
local function create_input(owner: owner): manifest
	return { owner = owner, products = {}, passes = {}, places = {} }
end
local function create_state(universe_id: number): lock
	return { universe_id = universe_id, products = {}, passes = {}, thumbnails = {}, places = {} }
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

	data.passes = base.string_map(data.passes, 'manifest.passes')
	for key, entry in data.passes do
		pass.validate_input(entry, `manifest.passes.{key}`)
	end

	if data.thumbnails ~= nil then
		data.thumbnails = base.list(data.thumbnails, 'manifest.thumbnails')
		for i, entry in data.thumbnails do
			thumbnail.validate_input(entry, `manifest.thumbnails[{i}]`)
		end
	end
	if data.icon ~= nil then icon.validate_input(data.icon, 'manifest.icon') end

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

	data.passes = base.string_map(data.passes, 'lock.passes')
	for key, entry in data.passes do
		pass.validate_lock(entry, `lock.passes.{key}`)
	end

	data.thumbnails = base.string_map(data.thumbnails, 'lock.thumbnails')
	for hash, entry in data.thumbnails do
		thumbnail.validate_lock(entry, `lock.thumbnails.{hash}`)
	end
	if data.icon ~= nil then
		base.req(data.icon, 'table', 'lock.icon')
		icon.validate_lock(data.icon, 'lock.icon')
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

	out.thumbnails = data.thumbnails and (base.encode_map(data.thumbnails, thumbnail.encode_input) or {})
	out.icon = data.icon and icon.encode_input(data.icon)
	out.products = base.encode_map(data.products, product.encode_input)
	out.places = base.encode_map(data.places, place.encode_input)
	out.passes = base.encode_map(data.passes, pass.encode_input)

	if data.universe then
		local encoded = universe.encode_input(data.universe)
		out.universe = if next(encoded) == nil then nil else encoded
	end

	return serde.encode('yaml', out, true)
end
local function encode_lock(data: lock): string
	local out: any = tbl.applied(data, { version = 1, products = {}, places = {} })

	out.products = base.encode_map(data.products, product.encode_lock_entry)
	out.passes = base.encode_map(data.passes, pass.encode_lock_entry)
	out.thumbnails = base.encode_map(data.thumbnails, thumbnail.encode_lock_entry)
	out.icon = data.icon and icon.encode_lock_entry(data.icon)
	out.places = base.encode_map(data.places, place.encode_lock_entry)

	return serde.encode('yaml', out, true)
end

-- resources
local function build_resources(inputs: manifest, locks: lock): resources
	inputs.passes, locks.passes = inputs.passes or {}, locks.passes or {}
	locks.thumbnails = locks.thumbnails or {}

	rekey.orphans(inputs.products, locks.products, product.diff)
	rekey.orphans(inputs.places, locks.places, place.diff)
	rekey.orphans(inputs.passes, locks.passes, pass.diff)

	local universe_entry = inputs.universe and { key = 'universe', input = inputs.universe, lock = locks.universe }

	local places = {}
	for key, input in inputs.places do
		table.insert(places, { key = key, input = input, lock = locks.places[key] })
	end

	local products = {}
	for key, input in inputs.products do
		table.insert(products, { key = key, input = input, lock = locks.products[key] })
	end

	local passes = {}
	for key, input in inputs.passes do
		table.insert(passes, { key = key, input = input, lock = locks.passes[key] })
	end

	local thumbnails = {}
	for i, input in inputs.thumbnails or {} :: { thumbnail.thumbnail_input } do
		local lock = input.image_file and locks.thumbnails[input.image_file.hash]
		table.insert(thumbnails, { key = input.file or `thumbnail {i}`, input = input, lock = lock })
	end
	local icon_entry = inputs.icon and { key = 'icon', input = inputs.icon, lock = locks.icon }

	return {
		products = products,
		passes = passes,
		thumbnails = thumbnails,
		icon = icon_entry,
		places = places,
		universe = universe_entry,
		manifest = inputs,
		lock = locks,
	}
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

	diff_thumbnail = thumbnail.diff,
	diff_icon = icon.diff,
	diff_universe = universe.diff,
	diff_product = product.diff,
	diff_place = place.diff,
	diff_pass = pass.diff,

	mask_universe = universe.mask,
	mask_product = product.mask,
	mask_place = place.mask,
	mask_pass = pass.mask,
}
