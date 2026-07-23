local cloud = require '@pkg/ro_cloud'
local http = require '@utils/http'
local tbl = require '@utils/tbl'

local sync = require '@lib/sync'
local types = require '@lib/types'

-- defs
local BASEPLATE_PLACE_ID = 95206881

-- functions
local function build_product_api(session: cloud.apikey_session): sync.cloud_api
	return {
		get = function(product)
			local path = `developer-product/{product.product_id}`
			return types.from_api_result(http.request('GET', path, function()
				return cloud.product.get(session, product)
			end))
		end,
		create = function(universe, data)
			local path = `universes/{universe.universe_id}/developer-products`
			return types.from_api_result(http.request('POST', path, function()
				return cloud.product.create(session, universe, types.to_api_params(data))
			end))
		end,
		update = function(product, patch)
			local path = `developer-product/{product.product_id}`
			return http.request('PATCH', path, function()
				return cloud.product.update(session, product, types.to_api_params(patch))
			end)
		end,
	}
end

local function build_universe_api(session: cloud.apikey_session, user_session: cloud.cookie_session): sync.universe_api
	return {
		get = function(u)
			local open = types.from_universe_api(http.request('GET', `universe/{u.universe_id}`, function()
				return cloud.universe.get(session, u)
			end))
			local config =
				types.from_universe_config(http.request('GET', `universes/{u.universe_id}/configuration`, function()
					return cloud.universe_configuration.get(user_session, u)
				end))
			return tbl.applied(open, config)
		end,
		update = function(u, patch)
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
		end,
	}
end

local function build_place_api(
	session: cloud.apikey_session,
	user_session: cloud.cookie_session,
	creator: any
): sync.place_api
	return {
		create = function(opts, place)
			local result = http.request('POST', 'assets (Place)', function()
				return cloud.place.create(
					user_session,
					{ universe_id = opts.universe_id },
					{ templatePlaceId = BASEPLATE_PLACE_ID }
				)
			end)
			return {
				universe_id = opts.universe_id,
				place_id = result.placeId,
			}
		end,
		get = function(place)
			return types.from_place_config(http.request('GET', `places/{place.place_id}`, function()
				return cloud.place_configuration.get(user_session, { place_id = place.place_id })
			end))
		end,
		update = function(place, patch)
			if patch.asset_file and patch.asset_file.content then
				http.request('POST', `places/{place.place_id}/versions`, function()
					return cloud.place.upload(session, place, patch.asset_file.content, true)
				end)
			end
			local config = types.to_place_config_params(patch)
			if next(config) ~= nil then
				return types.from_place_config(http.request('PATCH', `places/{place.place_id}`, function()
					return cloud.place_configuration.update(user_session, { place_id = place.place_id }, config)
				end))
			end
			return nil
		end,
	}
end

-- module
return table.freeze {
	build_product_api = build_product_api,
	build_universe_api = build_universe_api,
	build_place_api = build_place_api,
}
