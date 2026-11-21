local expect = require '@test/expect'
local mock = require '@test/mock'
local product = require '@lib/resources/product'
local sm = require '@test/sync_mock'

local HASH = string.rep('a', 64)
local function icon(hash: string): any
	return { hash = hash, content = buffer.create(0) }
end

local function raw_product(overrides: { [string]: any }?): any
	local raw: any = {
		universeId = sm.UNIVERSE_ID,
		productId = sm.PRODUCT_ID,
		name = 'Pack',
		priceInformation = { defaultPriceInRobux = 100, enabledFeatures = { 'RegionalPricing' } },
	}
	for k, v in overrides or {} :: { [string]: any } do
		raw[k] = v
	end
	return raw
end

local function create_with(raw: any, input: any): any
	return mock.with_http(function()
		return raw
	end, function()
		return product.create(nil :: any, { universe_id = sm.UNIVERSE_ID }, input)
	end)
end

local run = {}

function run.create_splits_identity_out_of_input()
	local lock = create_with(raw_product(), { name = 'Pack', conflicts = {} })

	expect.eq(lock.universe_id, sm.UNIVERSE_ID)
	expect.eq(lock.product_id, sm.PRODUCT_ID)
	expect.falsy(lock.input.universe_id, 'identity must not leak into input')
	expect.falsy(lock.input.product_id, 'identity must not leak into input')
	expect.eq(lock.input.name, 'Pack')
	expect.eq(lock.input.price, 100)
	expect.eq(lock.input.regional_pricing, true)
end

function run.create_icon_keeps_cloud_assetid_and_local_hash()
	local lock = create_with(
		raw_product { iconImageAssetId = sm.ICON_ID },
		{ name = 'Pack', icon_file = icon(HASH), conflicts = {} }
	)

	expect.eq(lock.input.icon_file.assetid, sm.ICON_ID) -- assetid comes from the cloud result
	expect.eq(lock.input.icon_file.hash, HASH) -- hash comes from the local file we uploaded
end

function run.create_icon_hash_preserved_when_result_has_no_icon()
	local lock = create_with(raw_product(), { name = 'Pack', icon_file = icon(HASH), conflicts = {} })

	expect.eq(lock.input.icon_file.hash, HASH)
	expect.falsy(lock.input.icon_file.assetid, 'no cloud assetid when the result had none')
end

function run.list_returns_reads_across_pages()
	local reads = mock.with_http(function(_, _, _)
		return { developerProducts = { raw_product(), raw_product { productId = 9, name = 'Other' } } }
	end, function()
		return product.list(nil :: any, { universe_id = sm.UNIVERSE_ID })
	end)

	expect.eq(#reads, 2)
	expect.eq(reads[1].product_id, sm.PRODUCT_ID)
	expect.eq(reads[2].product_id, 9)
	expect.eq(reads[2].name, 'Other')
end

return run
