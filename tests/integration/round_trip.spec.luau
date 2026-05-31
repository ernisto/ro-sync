local expect = require '@test/expect'
local fs = require '@lune/fs'
local mock = require '@test/mock'
local serde = require '@lune/serde'
local sm = require '@test/sync_mock'
local state = require '@lib/state'
local state_fs = require '@cli/state_fs'
local sync = require '@lib/sync'

local ICON_PATH = 'tests/integration/assets/placeholder.png'
local TMP_MANIFEST = 'tests/integration/assets/tmp_manifest.yml'
local TMP_LOCK = 'tests/integration/assets/tmp_lock.yml'

local run = {}

local function cleanup()
	if fs.isFile(TMP_MANIFEST) then fs.removeFile(TMP_MANIFEST) end
	if fs.isFile(TMP_LOCK) then fs.removeFile(TMP_LOCK) end
end

local function write_files(manifest: any, lock: any)
	fs.writeFile(TMP_MANIFEST, serde.encode('yaml', manifest, true))
	fs.writeFile(TMP_LOCK, serde.encode('yaml', lock, true))
end

local function run_sync(api: sync.cloud_api, opts: sync.sync_opts)
	local resources = state_fs.load_resources(TMP_MANIFEST, TMP_LOCK)
	for _, product in resources.products do
		product.lock = sync.await_reconcile_product(api, product, opts)
	end
	state_fs.save_resources(resources, TMP_MANIFEST, TMP_LOCK)
end

local OPTS: sync.sync_opts = { universe_id = sm.UNIVERSE_ID, force_fresh_state = false }

-- tests

function run.field_change_is_noop_on_second_sync()
	cleanup()

	write_files({ version = 1, owner = { group = 1 }, products = { test_pack = { name = 'New Name', price = 100 } } }, {
		version = 1,
		universe_id = sm.UNIVERSE_ID,
		products = {
			test_pack = {
				universe_id = sm.UNIVERSE_ID,
				product_id = sm.PRODUCT_ID,
				input = { name = 'Old Name', price = 100 },
			},
		},
	})

	local cloud_state = sm.make_input { name = 'Old Name', price = 100 }

	-- first sync: name changed locally → pushed
	local first_update = mock.fn()
	run_sync({
		create = mock.never_called 'create',
		get = function()
			return sm.cloud_mirror(cloud_state)
		end,
		update = first_update,
	}, OPTS)
	expect.eq(first_update.call_count, 1)

	-- second sync: lock now matches manifest → noop, no API calls
	run_sync(
		{ create = mock.never_called 'create', get = mock.never_called 'get', update = mock.never_called 'update' },
		OPTS
	)

	cleanup()
end

function run.icon_hash_is_noop_on_second_sync()
	cleanup()

	-- manifest references a real icon file; lock has a stale hash
	write_files(
		{ version = 1, owner = { group = 1 }, products = { test_pack = { name = 'Pack', icon = ICON_PATH } } },
		{
			version = 1,
			universe_id = sm.UNIVERSE_ID,
			products = {
				test_pack = {
					universe_id = sm.UNIVERSE_ID,
					product_id = sm.PRODUCT_ID,
					input = { name = 'Pack', icon_file = { assetid = sm.ICON_ID, hash = 'stale' } },
				},
			},
		}
	)

	local cloud_state = sm.make_input { icon = sm.make_icon_lock(sm.ICON_ID, nil) }

	-- first sync: stale hash differs from real file hash → icon pushed
	local first_update = mock.fn()
	run_sync({
		create = mock.never_called 'create',
		get = function()
			return sm.cloud_mirror(cloud_state)
		end,
		update = first_update,
	}, OPTS)
	expect.eq(first_update.call_count, 1)

	-- second sync: lock now has real hash → noop, no API calls
	run_sync(
		{ create = mock.never_called 'create', get = mock.never_called 'get', update = mock.never_called 'update' },
		OPTS
	)

	cleanup()
end

function run.create_writes_product_id_to_lock()
	cleanup()

	-- lock has no entry for test_pack → product gets created
	fs.writeFile(
		TMP_MANIFEST,
		serde.encode(
			'yaml',
			{ version = 1, owner = { group = 1 }, products = { test_pack = { name = 'Pack', price = 100 } } },
			true
		)
	)
	fs.writeFile(TMP_LOCK, `version: 1\nuniverse_id: {sm.UNIVERSE_ID}\nproducts: \{\{}}\n`)

	run_sync({
		create = function()
			return { universe_id = sm.UNIVERSE_ID, product_id = sm.PRODUCT_ID, name = 'Pack' }
		end,
		get = mock.never_called 'get',
		update = mock.never_called 'update',
	}, OPTS)

	local after = state_fs.load_resources(TMP_MANIFEST, TMP_LOCK)
	local lock = after.lock.products.test_pack
	expect.eq(lock.product_id, sm.PRODUCT_ID)
	expect.eq(lock.universe_id, sm.UNIVERSE_ID)

	cleanup()
end

function run.create_with_icon_writes_assetid_and_hash_to_lock()
	cleanup()

	-- lock has no entry for test_pack → product gets created with icon
	fs.writeFile(
		TMP_MANIFEST,
		serde.encode(
			'yaml',
			{ version = 1, owner = { group = 1 }, products = { test_pack = { name = 'Pack', icon = ICON_PATH } } },
			true
		)
	)
	fs.writeFile(TMP_LOCK, `version: 1\nuniverse_id: {sm.UNIVERSE_ID}\nproducts: \{\{}}\n`)

	run_sync({
		create = function()
			return {
				universe_id = sm.UNIVERSE_ID,
				product_id = sm.PRODUCT_ID,
				icon_file = { assetid = sm.ICON_ID },
				name = 'Pack',
			}
		end,
		get = mock.never_called 'get',
		update = mock.never_called 'update',
	}, OPTS)

	local after = state_fs.load_resources(TMP_MANIFEST, TMP_LOCK)
	local icon = after.lock.products.test_pack.input.icon_file
	assert(icon)
	expect.eq(icon.assetid, sm.ICON_ID)
	expect.truthy(icon.hash, 'hash should be saved alongside assetid')

	cleanup()
end

function run.conflict_is_written_to_manifest()
	cleanup()

	write_files(
		{ version = 1, owner = { group = 1 }, products = { test_pack = { name = 'Local Name', price = 100 } } },
		{
			version = 1,
			universe_id = sm.UNIVERSE_ID,
			products = {
				test_pack = {
					universe_id = sm.UNIVERSE_ID,
					product_id = sm.PRODUCT_ID,
					input = { name = 'Old Name', price = 100 },
				},
			},
		}
	)

	run_sync({
		create = mock.never_called 'create',
		get = function()
			return sm.cloud_mirror(sm.make_input { name = 'Cloud Name', price = 100 })
		end,
		update = function() end,
	}, OPTS)

	local after = state_fs.load_resources(TMP_MANIFEST, TMP_LOCK)
	local conflicts = after.products[1].input.conflicts
	expect.truthy(conflicts, 'conflicts not written to manifest')
	expect.truthy(conflicts.name, 'name conflict not written')

	cleanup()
end

function run.cloud_pull_is_written_to_manifest()
	cleanup()

	-- local changed name; cloud changed description (no overlap)
	write_files({
		version = 1,
		owner = { group = 1 },
		products = { test_pack = { name = 'New Name', price = 100, description = 'Old' } },
	}, {
		version = 1,
		universe_id = sm.UNIVERSE_ID,
		products = {
			test_pack = {
				universe_id = sm.UNIVERSE_ID,
				product_id = sm.PRODUCT_ID,
				input = { name = 'Old Name', price = 100, description = 'Old' },
			},
		},
	})

	run_sync({
		create = mock.never_called 'create',
		get = function()
			return sm.cloud_mirror(sm.make_input { name = 'Old Name', price = 100, description = 'From Cloud' })
		end,
		update = function() end,
	}, OPTS)

	local after = state_fs.load_resources(TMP_MANIFEST, TMP_LOCK)
	expect.eq(after.products[1].input.description, 'From Cloud')

	cleanup()
end

-- ── manifest nesting ───────────────────────────────────────────────────────────

-- the manifest groups social links and devices; parse flattens them, encode must re-nest
function run.universe_socials_devices_round_trip()
	local source = table.concat({
		'version: 1',
		'owner:',
		'  group: 1',
		'universe:',
		'  devices:',
		'    desktop: true',
		'  socials:',
		'    discord:',
		'      uri: https://discord.gg/x',
	}, '\n')

	local manifest = state.parse_manifest(buffer.fromstring(source))
	expect.eq(manifest.universe.desktop, true) -- nested → flat internally
	expect.eq(manifest.universe.discord.uri, 'https://discord.gg/x')

	local reparsed = state.parse_manifest(buffer.fromstring(state.encode_manifest(manifest)))
	expect.eq(reparsed.universe.desktop, true) -- survived flat → nested → flat
	expect.eq(reparsed.universe.discord.uri, 'https://discord.gg/x')
end

return run
