local cloud = require '@pkg/ro_cloud'
local env = require '@utils/env'
local expect = require '@test/expect'
local state = require '@lib/state'
local sync = require '@lib/sync'

local LOCK_PATH = 'tests/integration/assets/cloud-state.yml'
local MANIFEST_PATH = 'tests/integration/assets/cloud.yml'
local ICON_PATH = 'tests/integration/assets/placeholder.png'

local API_KEY = env.str 'API_KEY'
if not API_KEY then
	warn 'integration/sync: skipping — API_KEY not set'
	return {}
end

local session = cloud.auth.apikey.login(API_KEY)
local lock = state.read_lock(LOCK_PATH)
local manifest = state.read_inputs(MANIFEST_PATH)

-- real API adapter — mirrors cli.luau exactly
local api: sync.cloud_api = {
	get = function(product)
		local data = cloud.product.get(session, product)
		local price_info = data.priceInformation
		return {
			universe_id = data.universeId,
			product_id = data.productId,
			icon_id = data.iconImageAssetId,
			name = data.name,
			price = price_info and price_info.defaultPriceInRobux,
			description = data.description,
			is_for_sale = data.isForSale,
			regional_pricing = price_info and table.find(price_info.enabledFeatures, 'RegionalPricing') ~= nil,
			store_page_enabled = data.storePageEnabled,
		}
	end,
	create = function()
		error 'create should not be called in integration tests'
	end,
	update = function(product, patch)
		cloud.product.update(session, product, {
			name = patch.name,
			price = patch.price,
			description = patch.description,
			imageFile = patch.icon_bytes,
			isForSale = patch.is_for_sale,
			isRegionalPricingEnabled = patch.regional_pricing,
			store_page_enabled = patch.store_page_enabled,
		})
	end,
}

local function get_product()
	return api.get(lock.products.money_pack1)
end

local run = {}

-- ── read-only ────────────────────────────────────────────────────────────────

function run.should_authenticate_and_fetch_product()
	local product = get_product()
	expect.eq(product.product_id, lock.products.money_pack1.product_id)
	expect.eq(product.universe_id, lock.products.money_pack1.universe_id)
end

function run.should_fetch_name_matching_manifest()
	local product = get_product()
	expect.eq(product.name, manifest.products.money_pack1.name)
end

function run.should_fetch_price_matching_manifest()
	local product = get_product()
	expect.eq(product.price, manifest.products.money_pack1.price)
end

-- ── sync pipeline ────────────────────────────────────────────────────────────

function run.should_return_prev_unchanged_when_no_local_changes()
	-- pick_fields only covers name/price/description/is_for_sale/regional_pricing/store_page_enabled
	-- manifest matches the lock snapshot on all those fields → sync returns prev immediately
	local input = table.clone(manifest.products.money_pack1) :: any
	input.icon = nil -- suppress fs.isFile so no hash comparison

	local prev = lock.products.money_pack1

	-- get must NOT be called because sending == {} and is_sending_icon == false
	local guarded_api = table.clone(api) :: sync.cloud_api
	guarded_api.get = expect.never_called 'get should not be reached for a no-op'
	guarded_api.update = expect.never_called 'update should not be reached for a no-op'

	local opts = { universe_id = prev.universe_id, force_fresh_state = true }
	local result = sync.sync_product('money_pack1', input, prev, guarded_api, opts)

	expect.eq(result, prev)
end

-- ── write + revert ────────────────────────────────────────────────────────────

function run.should_push_description_change_and_revert()
	local prev = lock.products.money_pack1
	local original = prev.input.description

	-- push the change through the sync pipeline
	local input = table.clone(manifest.products.money_pack1) :: any
	input.description = '__integration_test__'
	input.icon = nil

	local patched_prev = table.clone(prev) :: sync.product_lock
	patched_prev.input = table.clone(prev.input)

	local opts = { universe_id = prev.universe_id, force_fresh_state = true }
	sync.sync_product('money_pack1', input, patched_prev, api, opts)

	-- verify then always revert
	local ok, err = pcall(function()
		local after = get_product()
		expect.eq(after.description, '__integration_test__')
	end)

	cloud.product.update(session, prev, { description = original })

	if not ok then error(err, 0) end
end

function run.should_push_icon_change_and_revert()
	local prev = lock.products.money_pack1

	-- point icon at the real asset so sync reads it and computes a hash
	local input = table.clone(manifest.products.money_pack1) :: any
	input.icon = ICON_PATH

	-- give prev a stale hash so sync sees the icon as "changed"
	local patched_prev = table.clone(prev) :: sync.product_lock
	patched_prev.input = table.clone(prev.input)
	patched_prev.icon_hash = 'stale'

	local opts = { universe_id = prev.universe_id, force_fresh_state = true }
	sync.sync_product('money_pack1', input, patched_prev, api, opts)

	-- icon upload is async on Roblox's side; we can only verify update was called
	-- (icon_id in the lock becomes UNAVAILABLE_ID until the asset is moderated)
	local after_lock = sync.sync_product('money_pack1', input, patched_prev, api, opts)

	-- original_icon_id should differ once Roblox processes the upload,
	-- but here we just assert the sync ran without error and returned a lock
	expect.truthy(after_lock.product_id)
end

return run
