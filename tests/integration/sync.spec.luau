local cloud = require '@pkg/ro_cloud'
local env = require '@utils/env'
local expect = require '@test/expect'
local mock = require '@test/mock'
local sm = require '@test/sync_mock'
local state = require '@lib/state'
local sync = require '@lib/sync'
local types = require '@lib/types'

local LOCK_PATH = 'tests/integration/assets/cloud-state.yml'
local MANIFEST_PATH = 'tests/integration/assets/cloud.yml'
local ICON_PATH = 'tests/integration/assets/placeholder.png'

local API_KEY = env.str 'API_KEY'
if not API_KEY then
	warn 'integration/sync: skipping — API_KEY not set'
	return {}
end

local session = cloud.auth.apikey.login(API_KEY)
local resources = state.read_resources(MANIFEST_PATH, LOCK_PATH)

-- real API adapter — mirrors cli.luau exactly
local api: sync.cloud_api = {
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

local run = {}

-- ── read-only ────────────────────────────────────────────────────────────────

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

-- ── sync pipeline ────────────────────────────────────────────────────────────

function run.should_return_prev_unchanged_when_no_local_changes()
	local prev = resources.lock.products.money_pack1
	local input = table.clone(resources.manifest.products.money_pack1) :: any
	input.icon = nil -- suppress icon change detection

	local guarded_api = table.clone(api) :: sync.cloud_api
	guarded_api.get = mock.never_called 'get should not be reached for a no-op'
	guarded_api.update = mock.never_called 'update should not be reached for a no-op'

	local opts: sync.sync_opts = { universe_id = prev.universe_id, force_fresh_state = false }
	local result = sync.await_reconcile_product(guarded_api, sm.make_product(input, prev), opts)

	expect.eq(result, prev)
end

-- ── write + revert ────────────────────────────────────────────────────────────

function run.should_push_description_change_and_revert()
	local prev = resources.lock.products.money_pack1
	local original = prev.input.description

	local input = table.clone(resources.manifest.products.money_pack1) :: any
	input.description = '__integration_test__'
	input.icon = nil

	local patched_prev = table.clone(prev) :: any
	patched_prev.input = table.clone(prev.input)

	local opts: sync.sync_opts = { universe_id = prev.universe_id, force_fresh_state = false }
	sync.await_reconcile_product(api, sm.make_product(input, patched_prev), opts)

	local ok, err = pcall(function()
		local after = get_product()
		expect.eq(after.description, '__integration_test__')
	end)

	cloud.product.update(session, prev, { description = original })

	if not ok then error(err, 0) end
end

function run.should_push_icon_change_and_revert()
	local prev = resources.lock.products.money_pack1
	local icon = state.maybe_resolve_file(ICON_PATH)

	local input = table.clone(resources.manifest.products.money_pack1) :: any
	input.icon = icon

	local patched_prev = table.clone(prev) :: any
	patched_prev.input = table.clone(prev.input)
	patched_prev.input.icon = { assetid = prev.input.icon and prev.input.icon.assetid, hash = 'stale' }

	local opts: sync.sync_opts = { universe_id = prev.universe_id, force_fresh_state = false }
	sync.await_reconcile_product(api, sm.make_product(input, patched_prev), opts)

	local after_lock = sync.await_reconcile_product(api, sm.make_product(input, patched_prev), opts)
	expect.truthy(after_lock.product_id)
end

return run
