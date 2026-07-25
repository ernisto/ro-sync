local cloud = require '@pkg/ro_cloud'
local env = require '@utils/env'
local expect = require '@test/expect'
local mock = require '@test/mock'
local sm = require '@test/sync_mock'
local state_fs = require '@cli/state_fs'
local sync = require '@lib/sync'
local types = require '@lib/types'

local LOCK_PATH = 'tests/integration/assets/cloud-state.yml'
local MANIFEST_PATH = 'tests/integration/assets/cloud.yml'
local ICON_PATH = 'tests/integration/assets/placeholder.png'

local API_KEY = env.str 'API_KEY'

local resources = state_fs.load_resources(MANIFEST_PATH, LOCK_PATH)

-- real API adapter — mirrors cli.luau exactly
local session = cloud.auth.apikey.login(API_KEY)
local api: sync.product_api = {
	get = function(product)
		local res = cloud.product.get(session, product)
		assert(res.ok, res.message)
		return types.from_api_result(res.body)
	end,
	create = function()
		error 'create should not be called in integration tests'
	end,
	update = function(product, patch)
		cloud.product.update(session, product, types.to_api_params(patch))
	end,
}

local function get_product()
	return api.get(resources.lock.products.money_pack1)
end

-- tests
local run = {}

function run.should_authenticate_and_fetch_product()
	local product = get_product()
	expect.eq(product.product_id, resources.lock.products.money_pack1.product_id)
	expect.eq(product.universe_id, resources.lock.products.money_pack1.universe_id)
end

function run.should_fetch_name_matching_manifest()
	local product = get_product()
	expect.eq(product.name, resources.manifest.products.money_pack1.name)
end

function run.should_fetch_price_matching_manifest()
	local product = get_product()
	expect.eq(product.price, resources.manifest.products.money_pack1.price)
end

function run.should_return_prev_unchanged_when_no_local_changes()
	local prev = resources.lock.products.money_pack1
	local input = table.clone(resources.manifest.products.money_pack1)
	input.icon = nil
	input.icon_file = nil

	local guarded_api = table.clone(api)
	guarded_api.get = mock.never_called 'get should not be reached for a no-op'
	guarded_api.update = mock.never_called 'update should not be reached for a no-op'

	local opts: sync.sync_opts = { universe_id = prev.universe_id }
	local result = sync.await_reconcile_product(guarded_api, sm.make_product(input, prev), opts)

	expect.eq(result, prev)
end

function run.should_push_description_change_and_revert()
	local prev = resources.lock.products.money_pack1
	local original = prev.input.description

	local input = table.clone(resources.manifest.products.money_pack1)
	input.description = '__integration_test__'
	input.icon = nil

	local patched_prev = table.clone(prev)
	patched_prev.input = table.clone(prev.input)

	local opts: sync.sync_opts = { universe_id = prev.universe_id }
	sync.await_reconcile_product(api, sm.make_product(input, patched_prev), opts)

	local ok, err = pcall(function()
		local after = get_product()
		expect.eq(after.description, '__integration_test__')
	end)

	cloud.product.update(session, prev, { name = prev.input.name, description = original })

	if not ok then error(err, 0) end
end

function run.should_push_icon_change_and_revert()
	local prev = resources.lock.products.money_pack1
	local icon = state_fs.resolve_file(ICON_PATH)

	local input = table.clone(resources.manifest.products.money_pack1)
	input.icon_file = icon

	local patched_prev = table.clone(prev)
	patched_prev.input = table.clone(prev.input)
	patched_prev.input.icon_file = { assetid = prev.input.icon_file and prev.input.icon_file.assetid, hash = 'stale' }

	local opts: sync.sync_opts = { universe_id = prev.universe_id }
	sync.await_reconcile_product(api, sm.make_product(input, patched_prev), opts)

	local after_lock = sync.await_reconcile_product(api, sm.make_product(input, patched_prev), opts)
	expect.truthy(after_lock.product_id)
end

return if API_KEY then run else { run = {}, skip = run }
