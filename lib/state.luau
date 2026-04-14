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
	name: string,
	icon: string?, -- saved as `icon: path`
	icon_file: file?, -- not readed from input
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
	_input_path: string,
	_lock_path: string,
}

-- constants
local UNAVAILABLE_ID = -1
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

-- Diffs two products over the tracked fields.
-- Icons are compared by hash but the diff value is the original file object.
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
	assert(manifest.version == 1, `unsupported version {manifest.version}`)
	assert(type(manifest.products) == 'table')

	for key, product in manifest.products do
		assert(type(product) == 'table')
		assert(type(key) == 'string')
		product.icon_file = product.icon and maybe_resolve_file(product.icon)
	end

	return manifest
end
local function ensure_lock(path: string): lock
	local content = maybe_read(path)
	if not content then return { version = 1, universe_id = UNAVAILABLE_ID, products = {} } end

	local lock = serde.decode('yaml', content)
	assert(lock.version == 1, `unsupported version {lock.version}`)
	assert(type(lock.products) == 'table')

	for key, product in lock.products do
		assert(type(key) == 'string')
		assert(type(product) == 'table')
	end

	return lock
end

local function save_manifest(path: string, data: manifest)
	local out: any = tbl.applied(data, { version = 1, products = {} })
	for k, product in data.products do
		out.products[k] = table.clone(product)
		out.products[k].icon_file = nil
		if product.conflicts and next(product.conflicts) == nil then out.products[k].conflicts = nil end
	end
	fs.writeFile(path, serde.encode('yaml', out, true))
end
local function save_lock(path: string, data: lock)
	local out = tbl.applied(data, { version = 1, products = {} })
	for k, product in data.products do
		local input = product.input
		local icon_file = input and input.icon_file

		local clean_icon = icon_file and tbl.intersection(icon_file, { assetid = 0, hash = '' })
		out.products[k] = tbl.applied(product, { input = tbl.applied(input, { icon_file = clean_icon }) })
	end
	fs.writeFile(path, serde.encode('yaml', out, true))
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
	PRODUCT_FIELDS = DIFF_PRODUCT_MASK,
}
