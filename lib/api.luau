local cloud = require '@pkg/ro_cloud'
local http = require '@utils/http'
local tbl = require '@utils/tbl'

local state = require '@lib/state'
local sync = require '@lib/sync'
local types = require '@lib/types'

-- defs
local BASEPLATE_PLACE_ID = 95206881

-- functions
local function build_product_api(session: cloud.apikey_session): sync.product_api
	local function get(product)
		local path = `developer-product/{product.product_id}`
		return types.from_api_result(http.request('GET', path, function()
			return cloud.product.get(session, product)
		end))
	end
	local function create(opts, data)
		local path = `universes/{opts.universe_id}/developer-products`
		local result = types.from_api_result(http.request('POST', path, function()
			return cloud.product.create(session, { universe_id = opts.universe_id }, types.to_api_params(data))
		end))

		return types.to_product_lock(result, data)
	end
	local function update(product, patch)
		local path = `developer-product/{product.product_id}`
		http.request('PATCH', path, function()
			return cloud.product.update(session, product, types.to_api_params(patch))
		end)
	end
	local function list(universe_id: number)
		local products = {}
		local token: string? = nil
		repeat
			local page = http.request('GET', `universes/{universe_id}/developer-products/creator`, function()
				return cloud.product.list(session, { universe_id = universe_id }, { pageToken = token })
			end)

			for _, product in page.developerProducts do
				table.insert(products, product)
			end
			token = if page.nextPageToken ~= '' then page.nextPageToken else nil
		until token == nil

		return products
	end
	return { get = get, create = create, update = update, list = list }
end

local function build_universe_api(session: cloud.apikey_session, user_session: cloud.cookie_session): sync.universe_api
	local function get(u)
		local open = types.from_universe_api(http.request('GET', `universe/{u.universe_id}`, function()
			return cloud.universe.get(session, u)
		end))
		local config =
			types.from_universe_config(http.request('GET', `universes/{u.universe_id}/configuration`, function()
				return cloud.universe_configuration.get(user_session, u)
			end))
		return tbl.applied(open, config)
	end
	local function update(u, patch)
		local applied: { [string]: any } = {}

		local open_params = types.to_universe_params(patch)
		if next(open_params) ~= nil then
			local res = http.request('PATCH', `universe/{u.universe_id}`, function()
				return cloud.universe.update(session, u, open_params)
			end)
			tbl.apply(applied, types.from_universe_api(res))
		end

		local config_params = types.to_universe_config_params(patch)
		if next(config_params) ~= nil then
			local res = http.request('PATCH', `universes/{u.universe_id}/configuration`, function()
				return cloud.universe_configuration.update(user_session, u, config_params)
			end)
			tbl.apply(applied, types.from_universe_config(res))
		end

		return if next(applied) ~= nil then applied else nil
	end
	return { get = get, update = update }
end

local function build_place_api(session: cloud.apikey_session, user_session: cloud.cookie_session): sync.place_api
	local function get(place)
		return types.from_place_config(http.request('GET', `places/{place.place_id}`, function()
			return cloud.place_configuration.get(user_session, { place_id = place.place_id })
		end))
	end
	local function update(place: cloud.place_identity, patch: state.place_input): state.place_data?
		local applied: { [string]: any } = {}

		if patch.asset_file and patch.asset_file.content then
			http.request('POST', `places/{place.place_id}/versions`, function()
				return cloud.place.upload(session, place, patch.asset_file.content, true)
			end)
			applied.asset_file = { hash = patch.asset_file.hash }
		end

		local config = types.to_place_config_params(patch)
		if next(config) ~= nil then
			local res = http.request('PATCH', `places/{place.place_id}`, function()
				return cloud.place_configuration.update(user_session, { place_id = place.place_id }, config)
			end)
			tbl.apply(applied, types.from_place_config(res))
		end

		return if next(applied) ~= nil then applied else nil
	end
	local function list(universe_id: number)
		local places = {}
		local cursor: string? = nil
		repeat
			local page = http.request('GET', `universes/{universe_id}/places`, function()
				return cloud.develop.list_universe_places(user_session, { universe_id = universe_id }, { cursor = cursor })
			end)

			for _, place in page.data do
				table.insert(places, place)
			end
			local next_cursor = page.nextPageCursor
			cursor = if next_cursor == '' or next_cursor == cursor then nil else next_cursor
		until cursor == nil

		return places
	end
	local function create(opts: sync.sync_opts, place: state.place_input): state.place_lock
		local result = http.request('POST', 'assets (Place)', function()
			return cloud.place.create(
				user_session,
				{ universe_id = opts.universe_id },
				{ templatePlaceId = BASEPLATE_PLACE_ID }
			)
		end)

		local identity = { universe_id = opts.universe_id, place_id = result.placeId }
		return {
			universe_id = identity.universe_id,
			place_id = identity.place_id,
			input = update(identity, place) or {},
		}
	end
	return { create = create, get = get, update = update, list = list }
end

-- module
return table.freeze {
	build_product_api = build_product_api,
	build_universe_api = build_universe_api,
	build_place_api = build_place_api,
}
