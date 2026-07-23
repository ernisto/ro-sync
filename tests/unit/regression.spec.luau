-- regression tests for reported sync bugs
-- each test encodes the *correct* behaviour; failing ones reproduce an open bug
local expect = require '@test/expect'
local mock = require '@test/mock'
local sm = require '@test/sync_mock'
local state = require '@lib/state'
local sync = require '@lib/sync'

local HASH_A = string.rep('a', 64)
local opts = sm.DEFAULT_OPTS

local run = {}

-- issue 1: creating a place must not leak universe_id/place_id into the `input` block.
-- symptom: state file shows place_id/universe_id nested under `input` (and duplicated at top level).
function run.place_create_does_not_leak_identity_into_input()
	local input = sm.make_place_input { file = 'game.rbxl', asset_file = sm.make_asset_file(HASH_A) }

	local api: sync.place_api = {
		create = function(create_opts, place)
			return {
				universe_id = create_opts.universe_id,
				place_id = sm.PLACE_ID,
				input = { display_name = place.display_name, asset_file = { hash = (place.asset_file :: any).hash } },
			} :: any
		end,
		get = mock.never_called 'get',
		update = mock.never_called 'update',
	}

	local lock = sync.await_reconcile_place(api, sm.make_place(input, nil), opts)

	expect.eq(lock.place_id, sm.PLACE_ID)
	expect.eq(lock.universe_id, sm.UNIVERSE_ID)
	expect.falsy((lock.input :: any).place_id, 'place_id must not leak into the input block')
	expect.falsy((lock.input :: any).universe_id, 'universe_id must not leak into the input block')
end

-- issue 1 (products): same identity leak on product creation.
function run.product_create_does_not_leak_identity_into_input()
	local input = sm.make_input()

	-- the adapter returns a ready product_lock; identity must stay out of `input`
	local api: sync.product_api = {
		create = function(create_opts)
			return {
				universe_id = create_opts.universe_id,
				product_id = sm.PRODUCT_ID,
				input = { name = 'Pack' },
			} :: any
		end,
		get = mock.never_called 'get',
		update = mock.never_called 'update',
	}

	local lock = sync.await_reconcile_product(api, sm.make_product(input), opts)

	expect.eq(lock.product_id, sm.PRODUCT_ID)
	expect.falsy((lock.input :: any).product_id, 'product_id must not leak into the input block')
	expect.falsy((lock.input :: any).universe_id, 'universe_id must not leak into the input block')
end

-- issue 3: place creation must push initial config + rbxl and record them in the lock,
-- so the very next sync is a no-op instead of re-detecting every field.
function run.place_create_saves_initial_config_and_file_to_lock()
	local input = sm.make_place_input {
		file = 'game.rbxl',
		asset_file = sm.make_asset_file(HASH_A),
		display_name = 'Start',
		description = 'Desc',
		server_size = 42,
	}

	local pushed: any = nil
	local api: sync.place_api = {
		-- mirror the cli create: it pushes config + rbxl via update and echoes the applied place
		create = function(create_opts, place)
			pushed = place
			return {
				universe_id = create_opts.universe_id,
				place_id = sm.PLACE_ID,
				input = {
					display_name = place.display_name,
					description = place.description,
					server_size = place.server_size,
					asset_file = { hash = (place.asset_file :: any).hash },
				},
			} :: any
		end,
		get = mock.never_called 'get',
		update = mock.never_called 'update',
	}

	local lock = sync.await_reconcile_place(api, sm.make_place(input, nil), opts)

	expect.truthy(pushed, 'create must receive the config to push')
	expect.eq(pushed.display_name, 'Start')

	-- lock.input must reflect the pushed config so a follow-up sync sees no changes
	expect.eq(lock.input.display_name, 'Start')
	expect.eq(lock.input.description, 'Desc')
	expect.eq(lock.input.server_size, 42)

	local asset = assert(lock.input.asset_file, 'asset_file must be recorded in the lock')
	expect.eq(asset.hash, HASH_A)
end

-- issue 2: `allowed_gear_types` is a settings list, not a file, and must not appear as a
-- perpetual change. It becomes phantom-changed when the lock never captured it on create.
function run.place_create_saves_allowed_gear_types_to_lock()
	local gear = { 'MeleeWeapons', 'Explosives' }
	local input = sm.make_place_input {
		file = 'game.rbxl',
		asset_file = sm.make_asset_file(HASH_A),
		allowed_gear_types = gear,
	}

	local api: sync.place_api = {
		create = function(create_opts, place)
			return {
				universe_id = create_opts.universe_id,
				place_id = sm.PLACE_ID,
				input = {
					allowed_gear_types = place.allowed_gear_types,
					asset_file = { hash = (place.asset_file :: any).hash },
				},
			} :: any
		end,
		get = mock.never_called 'get',
		update = mock.never_called 'update',
	}

	local lock = sync.await_reconcile_place(api, sm.make_place(input, nil), opts)

	expect.truthy(lock.input.allowed_gear_types, 'allowed_gear_types must be saved to the lock on create')
	-- with the list captured, an unchanged cloud must not diff it back as a change
	expect.falsy(next(state.diff_place(lock.input, lock.input)), 'identical gear lists must not diff')
end

-- issue 2 (diff sanity): equal gear lists never diff regardless of instance/order.
function run.gear_types_equal_lists_do_not_diff()
	local a = { allowed_gear_types = { 'A', 'B' }, display_name = 'X' }
	local b = { allowed_gear_types = { 'A', 'B' }, display_name = 'X' }
	expect.falsy(next(state.diff_place(a, b)), 'equal gear lists must produce no diff')
end

return { run = run }
