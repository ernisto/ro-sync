local cloud = require '@pkg/ro_cloud'
local state = require '@lib/state'
local sync_logger = require '@lib/sync_logger'
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

local function import(session: cloud.apikey_session, universe_id: number, resources: state.resources)
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

-- module
return table.freeze { import = import }
