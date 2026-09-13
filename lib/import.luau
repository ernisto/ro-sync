local place = require '@lib/resources/place'
local product = require '@lib/resources/product'
local state = require '@lib/state'
local sync_logger = require '@lib/sync_logger'
local universe = require '@lib/resources/universe'

-- functions
local function await_import_products(api: product.api, universe_id: number, resources: state.resources)
	local assetid_keys: { [number]: string } = {}
	for key, product_lock in resources.lock.products do
		assetid_keys[product_lock.product_id] = key
	end

	for _, raw in api.list(universe_id) do
		local known_key = assetid_keys[raw.productId]
		local read = product.from_api_result(raw)
		local key = known_key or `product_{raw.productId}`

		resources.lock.products[key] = {
			universe_id = read.universe_id,
			product_id = read.product_id,
			input = read,
		}

		local input = resources.manifest.products[key]
		resources.manifest.products[key] = if input
			then state.mask_product(read, input)
			else { name = raw.name, conflicts = {} }

		sync_logger.imported(key, raw.productId)
	end
end

local function await_import_places(api: place.api, universe_id: number, resources: state.resources)
	local placeid_keys: { [number]: string } = {}
	for key, place_lock in resources.lock.places do
		placeid_keys[place_lock.place_id] = key
	end

	for _, raw in api.list(universe_id) do
		local known_key = placeid_keys[raw.id]
		local read = place.from_place_config(raw)
		local key = known_key or `place_{raw.id}`

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
end

local function await_import_universe(api: universe.api, universe_id: number, resources: state.resources)
	if resources.lock.universe then return end

	local read = api.get { universe_id = universe_id }
	resources.lock.universe = { universe_id = universe_id, input = read }

	local input = resources.manifest.universe
	resources.manifest.universe = if input then state.mask_universe(read, input) else { conflicts = {} }

	sync_logger.imported('universe', universe_id)
end

-- module
return table.freeze {
	await_import_products = await_import_products,
	await_import_places = await_import_places,
	await_import_universe = await_import_universe,
}
