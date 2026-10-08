local expect = require '@test/expect'
local pass = require '@lib/resources/pass'
local sm = require '@test/sync_mock'
local state = require '@lib/state'

local run = {}

function run.from_api_result_maps_fields()
	local read = pass.from_api_result({
		name = 'VIP',
		gamePassId = 7,
		iconAssetId = 9,
		isForSale = true,
		description = 'd',
		priceInformation = { defaultPriceInRobux = 50, enabledFeatures = { 'RegionalPricing' } },
	}, sm.UNIVERSE_ID)

	expect.eq(read.pass_id, 7)
	expect.eq(read.universe_id, sm.UNIVERSE_ID)
	expect.eq(read.icon_file.assetid, 9)
	expect.eq(read.price, 50)
	expect.eq(read.regional_pricing, true)
end

function run.rejects_store_page_enabled()
	local ok = pcall(pass.validate_input, { name = 'VIP', store_page_enabled = true }, 'p')
	expect.falsy(ok, 'store_page_enabled is product-only')
end

function run.manifest_round_trips_passes()
	local manifest = state.parse_manifest(buffer.fromstring [[
version: 1
owner: { user: 1 }
passes:
  vip: { name: VIP, price: 50 }
]])
	local out = state.encode_manifest(manifest)

	expect.truthy(out:find 'vip', 'pass kept')
end

return run
