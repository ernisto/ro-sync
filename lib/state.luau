local serde = require '@lune/serde'
local tbl = require '@utils/tbl'
local yaml = require '@utils/yaml'

local asset = require '@lib/resources/asset'
local base = require '@lib/resources/base'
local config = require '@lib/resources/config'
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
	thumbnails: { thumbnail.thumbnail_input }?,
	icon: icon.icon_input?,
	configs: { [string]: config.config_input },
	assets: asset.assets_input?,
}
-- state holding every field the extending file doesnt write itself: merged on load, written back on save
export type extends = { file: string, rbxstore: nil } | { rbxstore: rbxstore, file: nil }
export type rbxstore = { store: string, scope: string?, key: string, universe: number? }
export type lock = {
	universe_id: number,
	extends: extends?,
	owned: { [string]: true }?, -- fields written in the extending file, set when `extends` is
	universe: universe.universe_lock?,
	passes: { [string]: pass.pass_lock },
	places: { [string]: place.place_lock },
	configs: { [string]: config.config_lock },
	products: { [string]: product.product_lock },
	thumbnails: { [string]: thumbnail.thumbnail_lock }, -- keyed by image hash
	icon: icon.icon_lock?,
	assets: asset.assets_lock?,
}
export type manifest = input

export type product = { key: string, lock: product.product_lock?, input: product.product_input }
export type pass = { key: string, lock: pass.pass_lock?, input: pass.pass_input }
export type thumbnail = { key: string, lock: thumbnail.thumbnail_lock?, input: thumbnail.thumbnail_input }
export type icon = { key: string, lock: icon.icon_lock?, input: icon.icon_input }
export type place = { key: string, lock: place.place_lock?, input: place.place_input }
export type universe = { key: string, lock: universe.universe_lock?, input: universe.universe_input }
export type config = { key: string, lock: config.config_lock?, input: config.config_input }
export type resources = {
	thumbnails: { thumbnail },
	icon: icon?,
	products: { product },
	places: { place },
	passes: { pass },
	universe: universe?,
	configs: { config },
	manifest: manifest,
	lock: lock,
}

-- constructors
local function create_input(owner: owner): manifest
	return { owner = owner, products = {}, passes = {}, places = {}, configs = {} }
end
local function create_state(universe_id: number): lock
	return {
		universe_id = universe_id,
		products = {},
		passes = {},
		thumbnails = {},
		places = {},
		configs = {},
		assets = {},
	}
end

-- parsing
local function parse_manifest(content: buffer): manifest
	local data = serde.decode('yaml', content)
	base.req(data, 'table', 'manifest')
	base.check(data.version == 1, `unsupported manifest version {tostring(data.version)}`)
	base.validate_owner(data.owner, 'manifest.owner')

	data.products = base.string_map(data.products, 'manifest.products')
	for key, entry in data.products do
		product.parse_input(entry, `manifest.products.{key}`)
	end

	data.passes = base.string_map(data.passes, 'manifest.passes')
	for key, entry in data.passes do
		pass.parse_input(entry, `manifest.passes.{key}`)
	end

	if data.thumbnails ~= nil then
		data.thumbnails = base.list(data.thumbnails, 'manifest.thumbnails')
		for i, entry in data.thumbnails do
			thumbnail.parse_input(entry, `manifest.thumbnails[{i}]`)
		end
	end
	if data.icon ~= nil then icon.parse_input(data.icon, 'manifest.icon') end

	data.places = base.string_map(data.places, 'manifest.places')
	for key, entry in data.places do
		place.parse_input(entry, `manifest.places.{key}`)
	end

	if data.universe ~= nil then universe.parse_input(data.universe, 'manifest.universe') end

	data.configs = base.string_map(data.configs, 'manifest.configs')
	for key, entry in data.configs do
		config.parse_input(entry, `manifest.configs.{key}`)
	end

	if data.assets ~= nil then asset.parse_input(data.assets, 'manifest.assets') end
	return data
end
local function parse_extends(t: any)
	base.req(t, 'table', 'lock.extends')
	base.check((t.file == nil) ~= (t.rbxstore == nil), 'lock.extends must set exactly one of file/rbxstore')
	if t.file ~= nil then return base.req(t.file, 'string', 'lock.extends.file') end

	local store = t.rbxstore
	base.req(store, 'table', 'lock.extends.rbxstore')
	base.req(store.store, 'string', 'lock.extends.rbxstore.store')
	base.opt(store.scope, 'string', 'lock.extends.rbxstore.scope')
	base.req(store.key, 'string', 'lock.extends.rbxstore.key')
	base.opt(store.universe, 'number', 'lock.extends.rbxstore.universe')
end

local function parse_lock_data(data: any): lock
	base.req(data, 'table', 'lock')
	base.check(data.version == 1, `unsupported lock version {tostring(data.version)}`)
	base.opt(data.universe_id, 'number', 'lock.universe_id')

	if data.extends ~= nil then
		parse_extends(data.extends)
		data.owned = {}
		for key in data do
			data.owned[key] = true
		end
	end

	data.products = base.string_map(data.products, 'lock.products')
	for key, entry in data.products do
		product.parse_lock(entry, `lock.products.{key}`)
	end

	data.passes = base.string_map(data.passes, 'lock.passes')
	for key, entry in data.passes do
		pass.parse_lock(entry, `lock.passes.{key}`)
	end

	data.thumbnails = base.string_map(data.thumbnails, 'lock.thumbnails')
	for hash, entry in data.thumbnails do
		thumbnail.parse_lock(entry, `lock.thumbnails.{hash}`)
	end
	if data.icon ~= nil then
		base.req(data.icon, 'table', 'lock.icon')
		icon.parse_lock(data.icon, 'lock.icon')
	end

	data.places = base.string_map(data.places, 'lock.places')
	for key, entry in data.places do
		place.parse_lock(entry, `lock.places.{key}`)
	end

	if data.universe ~= nil then
		base.req(data.universe, 'table', 'lock.universe')
		universe.parse_lock(data.universe, 'lock.universe')
	end

	data.configs = base.string_map(data.configs, 'lock.configs')
	for key, entry in data.configs do
		config.parse_lock(entry, `lock.configs.{key}`, key)
	end

	data.assets = asset.parse_lock(data.assets, 'lock.assets')
	return data
end
local function parse_lock(content: buffer): lock
	return parse_lock_data(serde.decode('yaml', content))
end

-- extended fields replace the ones the extending file doesnt own
local function merge_extended(lock: lock, raw: any)
	local shared: any = parse_lock_data(tbl.applied(raw or {}, { version = 1 }))
	local owned = lock.owned or {}

	for key, value in shared do
		if key == 'version' or key == 'extends' or key == 'owned' or owned[key] then continue end
		(lock :: any)[key] = value
	end
end

-- encoding
local function encode_manifest(data: manifest): string
	local out: any = tbl.applied(data, { version = 1 })

	out.thumbnails = data.thumbnails and (base.encode_map(data.thumbnails, thumbnail.encode_input) or {})
	out.icon = data.icon and icon.encode_input(data.icon)
	out.products = base.encode_map(data.products, product.encode_input)
	out.places = base.encode_map(data.places, place.encode_input)
	out.passes = base.encode_map(data.passes, pass.encode_input)
	out.configs = base.encode_map(data.configs, config.encode_input)

	if data.universe then
		local encoded = universe.encode_input(data.universe)
		out.universe = if next(encoded) == nil then nil else encoded
	end

	return yaml.encode(out)
end
local function encode_lock_data(data: lock): { [string]: any }
	local out: any = tbl.applied(data, { version = 1 })
	out.owned = nil

	out.products = base.encode_map(data.products, product.encode_lock_entry)
	out.passes = base.encode_map(data.passes, pass.encode_lock_entry)
	out.thumbnails = base.encode_map(data.thumbnails, thumbnail.encode_lock_entry)
	out.places = base.encode_map(data.places, place.encode_lock_entry)
	out.configs = base.encode_map(data.configs, config.encode_lock_entry)
	out.icon = if data.icon then icon.encode_lock_entry(data.icon) else nil
	out.assets = if data.assets and next(data.assets) then data.assets else nil
	return out
end
local function encode_lock(data: lock): string
	return yaml.encode(encode_lock_data(data))
end

-- (own fields, extended fields) of a lock with `extends`
local function split_lock(data: lock): ({ [string]: any }, { [string]: any })
	local out = encode_lock_data(data)
	local owned = data.owned or {}
	local own, shared = { version = 1, extends = out.extends }, { version = 1 }

	for key, value in out do
		if key == 'version' or key == 'extends' then continue end
		if owned[key] then
			own[key] = value
		else
			shared[key] = value
		end
	end
	return own, shared
end

-- resources
local function build_resources(inputs: manifest, locks: lock): resources
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

	-- older manifests/locks predate configs
	inputs.configs = inputs.configs or {}
	locks.configs = locks.configs or {}

	local configs = {}
	for key, input in inputs.configs do
		config.arrange(input, locks.configs[key])
		table.insert(configs, { key = key, input = input, lock = locks.configs[key] })
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
		configs = configs,
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
	split_lock = split_lock,
	merge_extended = merge_extended,
	build_resources = build_resources,

	diff_thumbnail = thumbnail.diff,
	diff_icon = icon.diff,
	diff_universe = universe.diff,
	diff_product = product.diff,
	diff_place = place.diff,
	diff_pass = pass.diff,
	diff_config = config.diff,

	mask_universe = universe.mask,
	mask_product = product.mask,
	mask_place = place.mask,
	mask_pass = pass.mask,
	mask_config = config.mask,
}
