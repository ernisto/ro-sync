local base = require '@lib/resources/base'
local ctx_log = require '@utils/ctx_log'
local pass = require '@lib/resources/pass'
local place = require '@lib/resources/place'
local product = require '@lib/resources/product'
local rekey = require '@lib/rekey'
local state = require '@lib/state'
local sync_logger = require '@lib/sync_logger'
local universe = require '@lib/resources/universe'

type universe_api = typeof(universe)
type product_api = typeof(product)
type place_api = typeof(place)
type pass_api = typeof(pass)
export type picker = (fallback: string, name: string, free: { string }) -> string

type pending = { read: any, fallback: string, name: string }

-- helpers
local function keep_fallback(fallback: string, _name: string, _free: { string }): string
	return fallback
end

-- imports with no reused key pick an untracked manifest key or keep the fallback (new input)
local function assign_pending(
	pendings: { pending },
	inputs: { [string]: any },
	locks: { [string]: any },
	pick: picker?,
	apply: (key: string, read: any) -> ()
)
	local free: { string } = {}
	for key in inputs do
		if not locks[key] then table.insert(free, key) end
	end
	table.sort(free)

	for _, entry in pendings do
		local key = (pick or keep_fallback)(entry.fallback, entry.name, free)
		local i = table.find(free, key)
		if i then table.remove(free, i) end
		apply(key, entry.read)
	end
end

-- functions
local function await_import_products(
	api: product_api,
	session: base.session,
	universe_id: number,
	resources: state.resources,
	pick: picker?
)
	local assetid_keys: { [number]: string } = {}
	for key, product_lock in resources.lock.products do
		assetid_keys[product_lock.product_id] = key
	end

	local function apply(key: string, read: any)
		resources.lock.products[key] = {
			universe_id = read.universe_id,
			product_id = read.product_id,
			input = read,
		}

		local input = resources.manifest.products[key]
		resources.manifest.products[key] = if input
			then state.mask_product(read, input)
			else { name = read.name, conflicts = {} }

		sync_logger.imported(key, read.product_id)
	end

	local pendings: { pending } = {}
	for _, raw in api.list(session, { universe_id = universe_id }) do
		local read = product.from_api_result(raw)
		local key = assetid_keys[raw.productId]
			or rekey.matching_key(resources.manifest.products, resources.lock.products, read, product.diff)

		if key then
			apply(key, read)
		else
			table.insert(pendings, { read = read, fallback = `product_{raw.productId}`, name = raw.name })
		end
	end
	assign_pending(pendings, resources.manifest.products, resources.lock.products, pick, apply)
end

local function await_import_passes(
	api: pass_api,
	session: base.session,
	universe_id: number,
	resources: state.resources,
	pick: picker?
)
	local passid_keys: { [number]: string } = {}
	for key, pass_lock in resources.lock.passes do
		passid_keys[pass_lock.pass_id] = key
	end

	local function apply(key: string, read: any)
		resources.lock.passes[key] = {
			universe_id = universe_id,
			pass_id = read.pass_id,
			input = read,
		}

		local input = resources.manifest.passes[key]
		resources.manifest.passes[key] = if input
			then state.mask_pass(read :: any, input)
			else { name = read.name, conflicts = {} }

		sync_logger.imported(key, read.pass_id)
	end

	local pendings: { pending } = {}
	for _, raw in api.list(session, { universe_id = universe_id }) do
		local read = pass.from_api_result(raw, universe_id)
		local key = passid_keys[read.pass_id]
			or rekey.matching_key(resources.manifest.passes, resources.lock.passes, read, pass.diff)

		if key then
			apply(key, read)
		else
			table.insert(pendings, { read = read, fallback = `pass_{read.pass_id}`, name = read.name })
		end
	end
	assign_pending(pendings, resources.manifest.passes, resources.lock.passes, pick, apply)
end

local function await_import_places(
	api: place_api,
	session: base.session,
	universe_id: number,
	resources: state.resources,
	pick: picker?
)
	local placeid_keys: { [number]: string } = {}
	for key, place_lock in resources.lock.places do
		placeid_keys[place_lock.place_id] = key
	end

	local function apply(key: string, raw: any)
		local read = place.from_place_config(raw)
		resources.lock.places[key] = {
			universe_id = universe_id,
			place_id = raw.id,
			input = read,
		}

		local input = resources.manifest.places[key]
		resources.manifest.places[key] = if input
			then state.mask_place(read, input)
			else { display_name = raw.name, conflicts = {} }

		sync_logger.imported(key, raw.id)
	end

	local pendings: { pending } = {}
	for _, raw in api.list(session, { universe_id = universe_id }) do
		local key = placeid_keys[raw.id]
			or rekey.matching_key(
				resources.manifest.places,
				resources.lock.places,
				place.from_place_config(raw),
				place.diff
			)

		if key then
			apply(key, raw)
		else
			table.insert(pendings, { read = raw, fallback = `place_{raw.id}`, name = raw.name })
		end
	end
	assign_pending(pendings, resources.manifest.places, resources.lock.places, pick, apply)
end

local function await_import_universe(
	api: universe_api,
	session: base.session,
	universe_id: number,
	resources: state.resources
)
	if resources.lock.universe then return end

	local read = api.get(session, { universe_id = universe_id })
	resources.lock.universe = { universe_id = universe_id, input = read }

	local input = resources.manifest.universe
	resources.manifest.universe = if input then state.mask_universe(read, input) else { conflicts = {} }

	sync_logger.imported('universe', universe_id)
end

local function await_import_all(session: base.session, resources: state.resources, universe_id: number, pick: picker?)
	ctx_log.pcall(function()
		await_import_places(place, session, universe_id, resources, pick)
	end)
	ctx_log.pcall(function()
		await_import_universe(universe, session, universe_id, resources)
	end)
	ctx_log.pcall(function()
		await_import_products(product, session, universe_id, resources, pick)
	end)
	ctx_log.pcall(function()
		await_import_passes(pass, session, universe_id, resources, pick)
	end)
end

-- module
return table.freeze {
	await_import_universe = await_import_universe,
	await_import_products = await_import_products,
	await_import_passes = await_import_passes,
	await_import_places = await_import_places,
	await_import_all = await_import_all,
}
