local expect = require '@test/expect'
local mock = require '@test/mock'
local import = require '@lib/import'

local UNIVERSE_ID = 1000
local PRODUCT_ID = 2000
local PLACE_ID = 4000

-- raw cloud-shaped payloads (what the list/get endpoints return)
local function raw_product(overrides: { [string]: any }?): any
	local base = {
		universeId = UNIVERSE_ID,
		productId = PRODUCT_ID,
		name = 'Cloud Pack',
		description = 'A pack',
		isForSale = true,
		storePageEnabled = false,
		iconImageAssetId = 0,
		priceInformation = { defaultPriceInRobux = 100, enabledFeatures = {} },
	}
	for k, v in (overrides or {}) :: { [string]: any } do
		base[k] = v
	end
	return base
end
local function raw_place(overrides: { [string]: any }?): any
	local base = { id = PLACE_ID, name = 'Start', description = 'A place', maxPlayerCount = 50 }
	for k, v in (overrides or {}) :: { [string]: any } do
		base[k] = v
	end
	return base
end

local function empty_resources(): any
	return { lock = { products = {}, places = {} }, manifest = { products = {}, places = {} } }
end

local run = {}

-- products
function run.imports_new_product_into_lock_and_manifest()
	local resources = empty_resources()
	local api: any = {
		list = function()
			return { raw_product() }
		end,
		get = mock.never_called 'get',
		create = mock.never_called 'create',
		update = mock.never_called 'update',
	}

	import.await_import_products(api, UNIVERSE_ID, resources)

	local lock = resources.lock.products.product_2000
	expect.truthy(lock, 'lock entry created under product_<id> key')
	expect.eq(lock.product_id, PRODUCT_ID)
	expect.eq(lock.input.price, 100)
	expect.eq(resources.manifest.products.product_2000.name, 'Cloud Pack')
end

function run.masks_existing_manifest_product_by_matching_id()
	local resources = empty_resources()
	-- lock already tracks this product under a user-chosen key
	resources.lock.products.money_pack = { universe_id = UNIVERSE_ID, product_id = PRODUCT_ID, input = {} }
	resources.manifest.products.money_pack =
		{ name = 'Local Name', price = 100, description = 'A pack', is_for_sale = true, conflicts = {} }

	local api: any = {
		list = function()
			return { raw_product() }
		end,
		get = mock.never_called 'get',
		create = mock.never_called 'create',
		update = mock.never_called 'update',
	}

	import.await_import_products(api, UNIVERSE_ID, resources)

	-- keeps the existing key, does not create a product_<id> duplicate
	expect.falsy(resources.manifest.products.product_2000, 'known id must reuse existing key')

	local masked = resources.manifest.products.money_pack
	expect.eq(masked.name, 'Local Name') -- diverges from cloud → kept
	expect.falsy(masked.price, 'price equal to cloud should be masked out')
end

-- places
function run.imports_new_place_into_lock_and_manifest()
	local resources = empty_resources()
	local api: any = {
		list = function()
			return { raw_place() }
		end,
		get = mock.never_called 'get',
		create = mock.never_called 'create',
		update = mock.never_called 'update',
	}

	import.await_import_places(api, UNIVERSE_ID, resources)

	local lock = resources.lock.places.Start
	expect.truthy(lock, 'lock entry created under place name key')
	expect.eq(lock.place_id, PLACE_ID)
	expect.eq(lock.input.server_size, 50) -- maxPlayerCount mapped to server_size
	expect.eq(resources.manifest.places.Start.display_name, 'Start')
end

-- universe
function run.imports_universe_from_merged_read()
	local resources = empty_resources()
	local read = { desktop = true, mobile = true, private_server_price = 0 }
	local api: any = {
		get = function()
			return read
		end,
		update = mock.never_called 'update',
	}

	import.await_import_universe(api, UNIVERSE_ID, resources)

	expect.eq(resources.lock.universe.input, read)
	expect.truthy(resources.manifest.universe.conflicts, 'default manifest carries empty conflicts')
end

function run.skips_universe_when_lock_present()
	local resources = empty_resources()
	resources.lock.universe = { universe_id = UNIVERSE_ID, input = {} }
	local api: any = { get = mock.never_called 'get should not run when lock exists', update = function() end }

	import.await_import_universe(api, UNIVERSE_ID, resources)
end

return run
