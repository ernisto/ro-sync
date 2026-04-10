local ctx_log = require '@utils/ctx_log'
local fs = require '@lune/fs'
local serde = require '@lune/serde'
local tbl = require '@utils/tbl'

-- types
type owner = { user: nil, group: number } | { user: number, group: nil }
export type file_input = { hash: string, path: string, content: buffer, assetid: nil }
export type file_lock = { hash: string?, path: nil, content: nil, assetid: number }
export type file = file_input | file_lock

export type manifest = { owner: owner, products: { [string]: product_input } }
export type lock = { universe_id: number, products: { [string]: product_lock } }

export type product_input = {
	icon: file?, -- saved as `icon: path`
	name: string,
	price: number?,
	description: string?,
	is_for_sale: boolean?,
	regional_pricing: boolean?,
	store_page_enabled: boolean?,
	conflicts: { [string]: any }?,
	[string]: any,
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
	_input_path: string,
	_lock_path: string,
}

-- constants
local UNAVAILABLE_ID = -1
local PRODUCT_MASK = {
	name = '',
	icon = {} :: file,
	price = 0,
	description = '',
	is_for_sale = true,
	regional_pricing = true,
	store_page_enabled = true,
}

-- functions

-- Diffs two products over the tracked fields.
-- Icons are compared by hash but the diff value is the original file object.
local function normalize(source: { [string]: any }): { [string]: any }
	local result = tbl.intersection(source, PRODUCT_MASK)
	if type(result.icon) == 'table' then result.icon = (result.icon :: any).hash end
	return result
end
local function diff_product(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	local changes = tbl.changes(normalize(from), normalize(to))
	if changes.icon ~= nil then changes.icon = to.icon end
	return changes
end

local function maybe_read(path: string): buffer?
	return fs.isFile(path) and buffer.fromstring(fs.readFile(path)) or nil
end
local function maybe_resolve_file(path: string): file?
	local content = maybe_read(path)
	if not content then
		ctx_log.warn(`file '{path}' doesnt exist`)
		return
	end
	return table.freeze { path = path, content = content, hash = serde.hash('sha256', content) }
end

local function ensure_manifest(path: string): manifest
	local content = maybe_read(path)
	if not content then return { owner = { group = UNAVAILABLE_ID }, products = {} } end

	local manifest = serde.decode('yaml', content)
	assert(type(manifest.products) == 'table')

	for key, product in manifest.products do
		assert(type(product) == 'table')
		assert(type(key) == 'string')
		product.icon = product.icon and maybe_resolve_file(product.icon)
	end

	return manifest
end
local function ensure_lock(path: string): lock
	local content = maybe_read(path)
	if not content then return { universe_id = UNAVAILABLE_ID, products = {} } end

	local lock = serde.decode('yaml', content)
	assert(type(lock.products) == 'table')

	for key, product in lock.products do
		assert(type(key) == 'string')
		assert(type(product) == 'table')
		-- migrate old flat icon_id/icon_hash to nested input.icon
		if product.icon_id ~= nil then
			if product.input then product.input.icon = { assetid = product.icon_id, hash = product.icon_hash } end
			product.icon_id = nil
			product.icon_hash = nil
		elseif product.input and type(product.input.icon) == 'string' then
			product.input.icon = nil -- old path string with no hash info; treat as unknown
		end
	end

	return lock
end

local function save_manifest(path: string, data: manifest)
	local out = table.clone(data)
	for k, product in data.products do
		out.products[k] = tbl.applied(product, { icon = product.icon and product.icon.path })
	end
	fs.writeFile(path, serde.encode('yaml', out, true))
end
local function save_lock(path: string, data: lock)
	fs.writeFile(path, serde.encode('yaml', data, true))
end

local function read_resources(input_path: string, lock_path: string): resources
	local inputs = ensure_manifest(input_path)
	local locks = ensure_lock(lock_path)

	local products = {}
	for key, input in inputs.products do
		table.insert(products, { key = key, input = input, lock = locks.products[key] })
	end

	return { products = products, manifest = inputs, lock = locks, _input_path = input_path, _lock_path = lock_path }
end
local function save_resources(resources: resources)
	for _, product in resources.products do
		if product.lock then resources.lock.products[product.key] = product.lock end
	end
	save_lock(resources._lock_path, resources.lock)
	save_manifest(resources._input_path, resources.manifest)
end

-- module
return table.freeze {
	maybe_resolve_file = maybe_resolve_file,
	read_resources = read_resources,
	save_resources = save_resources,
	diff_product = diff_product,

	UNAVAILABLE_ID = UNAVAILABLE_ID,
	PRODUCT_FIELDS = PRODUCT_MASK,
}
