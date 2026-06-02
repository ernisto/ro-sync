local cloud = require '@pkg/ro_cloud'
local state = require '@lib/state'
local sync_logger = require '@lib/sync_logger'
local tbl = require '@utils/tbl'
local types = require '@lib/types'

-- functions
local function await_all_products(session: cloud.apikey_session, universe_id: number)
	local products = {}
	local token: string? = nil
	repeat
		local page_res = cloud.product.list(session, { universe_id = universe_id }, { pageToken = token })
		local page = assert(page_res.ok and page_res.body, page_res.message)

		for _, product in page.developerProducts do
			table.insert(products, product)
		end
		token = if page.nextPageToken ~= '' then page.nextPageToken else nil
	until token == nil

	return products
end

local function await_all_places(cookie: cloud.cookie_session, universe_id: number)
	local places = {}
	local cursor: string? = nil
	repeat
		local res = cloud.develop.list_universe_places(cookie, { universe_id = universe_id }, { cursor = cursor })
		local page = assert(res.ok and res.body, res.message)

		for _, place in page.data do
			table.insert(places, place)
		end
		local next_cursor = page.nextPageCursor
		cursor = if next_cursor == '' or next_cursor == cursor then nil else next_cursor
	until cursor == nil

	return places
end

local function await_import_products(session: cloud.apikey_session, universe_id: number, resources: state.resources)
	local known_ids: { [number]: boolean } = {}
	for _, product_lock in resources.lock.products do
		known_ids[product_lock.product_id] = true
	end

	for _, product in await_all_products(session, universe_id) do
		if known_ids[product.productId] then continue end
		local key = product.name

		if resources.manifest.products[key] then key = `{product.name}_{product.productId}` end
		local read = types.from_api_result(product)

		resources.manifest.products[key] = { name = product.name, conflicts = {} }
		resources.lock.products[key] = {
			universe_id = read.universe_id,
			product_id = read.product_id,
			input = read,
		}

		sync_logger.imported(key, product.productId)
	end
end

local function await_import_places(cookie: cloud.cookie_session, universe_id: number, resources: state.resources)
	local known_ids: { [number]: boolean } = {}
	for _, place_lock in resources.lock.places do
		known_ids[place_lock.place_id] = true
	end

	for _, place in await_all_places(cookie, universe_id) do
		if known_ids[place.id] then continue end
		local key = place.name

		if resources.manifest.places[key] then key = `{place.name}_{place.id}` end
		local read = types.from_place_config(place)

		resources.manifest.places[key] = { display_name = place.name, conflicts = {} }
		resources.lock.places[key] = { universe_id = universe_id, place_id = place.id, input = read }

		sync_logger.imported(key, place.id)
	end
end

local function await_import_universe(
	session: cloud.apikey_session,
	cookie: cloud.cookie_session,
	universe_id: number,
	resources: state.resources
)
	if resources.lock.universe then return end

	local open_res = cloud.universe.get(session, { universe_id = universe_id })
	local open = assert(open_res.ok and open_res.body, open_res.message)

	local config_res = cloud.universe_configuration.get(cookie, { universe_id = universe_id })
	local config = assert(config_res.ok and config_res.body, config_res.message)

	local read = tbl.applied(types.from_universe_api(open), types.from_universe_config(config))

	resources.manifest.universe = { conflicts = {} }
	resources.lock.universe = { universe_id = universe_id, input = read }

	sync_logger.imported('universe', universe_id)
end

-- module
return table.freeze {
	await_import_products = await_import_products,
	await_import_places = await_import_places,
	await_import_universe = await_import_universe,
}
