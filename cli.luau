local import = require '@lib/import'
local task = require '@lune/task'

local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'

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

local session = cloud.auth.apikey.login(API_KEY)

local function log_http_call<T>(method: string, path: string, fn: () -> T): T
	local ok, result = pcall(fn)
	if ok then
		ctx_log.http(method, path, true, 200)
		return result :: T
	end

	local err = tostring(result)
	local code = tonumber(err:match '%[(%d+)%]')
	local msg = err:match 'Request fail %[%d+%]: (.-)[\n$]' or err:match 'Request fail %[%d+%]: (.+)' or err
	ctx_log.http(method, path, false, code, msg)
	error(result, 0)
end

local api: sync.cloud_api = {
	get = function(product)
		local path = `developer-product/{product.product_id}`
		return log_http_call('GET', path, function()
			return types.from_api_result(cloud.product.get(session, product))
		end)
	end,
	create = function(universe, data)
		local path = `universes/{universe.universe_id}/developer-products`
		return log_http_call('POST', path, function()
			return types.from_api_result(cloud.product.create(session, universe, types.to_api_params(data)))
		end)
	end,
	update = function(product, patch)
		local path = `developer-product/{product.product_id}`
		return log_http_call('PATCH', path, function()
			cloud.product.update(session, product, types.to_api_params(patch))
			return nil
		end)
	end,
}

sync_logger.print_header()

-- main
local resources = state.read_resources(INPUTS_PATH, LOCK_PATH)
local sync_opts = { universe_id = resources.lock.universe_id, force_fresh_state = force_fresh_state }

local remaining = 0
for _, resource in resources.products do
	remaining += 1
	task.spawn(function()
		resource.lock = sync.await_reconcile_product(api, resource, sync_opts)
	end)
end
while remaining > 0 do
	task.wait()
end

if detect_new then import.import(session, resources.lock.universe_id, resources) end

sync_logger.print_summary()
state.save_resources(resources)
