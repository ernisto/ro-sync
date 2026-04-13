local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'
local http_log = require '@utils/http_log'
local c = ctx_log.colors

local import = require '@lib/import'
local state = require '@lib/state'
local sync = require '@lib/sync'
local sync_logger = require '@lib/sync_logger'
local types = require '@lib/types'

-- cli
local API_KEY = cli.str 'api-key' or env.str 'API_KEY' or error 'missing api key'
local INPUTS_PATH = cli.str 'manifest' or 'cloud.yml'
local LOCK_PATH = cli.str 'state' or 'cloud-state.yml'
local force_fresh_state = cli.bool 'fresh-state'
local detect_new = cli.bool 'detect-new'

-- defs
local session = cloud.auth.apikey.login(API_KEY)
local api: sync.cloud_api = {
	get = function(product)
		local path = `developer-product/{product.product_id}`
		return types.from_api_result(http_log.log_http_call('GET', path, function()
			return cloud.product.get(session, product)
		end))
	end,
	create = function(universe, data)
		local path = `universes/{universe.universe_id}/developer-products`
		return types.from_api_result(http_log.log_http_call('POST', path, function()
			return cloud.product.create(session, universe, types.to_api_params(data))
		end))
	end,
	update = function(product, patch)
		local path = `developer-product/{product.product_id}`
		return http_log.log_http_call('PATCH', path, function()
			return cloud.product.update(session, product, types.to_api_params(patch))
		end)
	end,
}

-- main
local resources = state.read_resources(INPUTS_PATH, LOCK_PATH)
local sync_opts = { universe_id = resources.lock.universe_id, force_fresh_state = force_fresh_state }
local universe = http_log.log_http_call('GET', `universe/{resources.lock.universe_id}`, function()
	return cloud.universe.get(session, { universe_id = resources.lock.universe_id })
end)

sync_logger.print_header()
ctx_log.str(`Logged in API Key: {c.green}"{string.sub(API_KEY, 1, 10)}..."`)
ctx_log.str(`Target universe: {c.bold}{universe.displayName}{c.reset} {c.dim}({resources.lock.universe_id})`)
ctx_log.str ''

for _, resource in resources.products do
	resource.lock = sync.await_reconcile_product(api, resource, sync_opts)
end

if detect_new then import.import(session, resources.lock.universe_id, resources) end

sync_logger.print_summary()
state.save_resources(resources)
