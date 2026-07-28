local state = require '@lib/state'
local sync = require '@lib/sync'
local sync_logger = require '@lib/sync_logger'
local types = require '@lib/types'

-- functions
local function await_import_products(api: sync.product_api, universe_id: number, resources: state.resources)
	local assetid_keys: { [number]: string } = {}
	for key, product_lock in resources.lock.products do
		assetid_keys[product_lock.product_id] = key
	end

	local list = assert(api.list, 'product api missing list')
	for _, product in list(universe_id) do
		local known_key = assetid_keys[product.productId]
		local read = types.from_api_result(product)
		local key = known_key or `product_{product.productId}`

		resources.lock.products[key] = {
			universe_id = read.universe_id,
			product_id = read.product_id,
			input = read,
		}

		local input = resources.manifest.products[key]
		resources.manifest.products[key] = if input
			then state.mask_product(read, input)
			else { name = product.name, conflicts = {} }

		sync_logger.imported(key, product.productId)
	end
end

local function await_import_places(api: sync.place_api, universe_id: number, resources: state.resources)
	local placeid_keys: { [number]: string } = {}
	for key, place_lock in resources.lock.places do
		placeid_keys[place_lock.place_id] = key
	end

	local list = assert(api.list, 'place api missing list')
	for _, place in list(universe_id) do
		local key = placeid_keys[place.id] or place.name
		local read = types.from_place_config(place)

		resources.lock.places[key] = { universe_id = universe_id, place_id = place.id, input = read }

		local input = resources.manifest.places[key]
		resources.manifest.places[key] = if input
			then state.mask_place(read, input)
			else { display_name = place.name, conflicts = {} }

		sync_logger.imported(key, place.id)
	end
end

local function await_import_universe(api: sync.universe_api, universe_id: number, resources: state.resources)
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
