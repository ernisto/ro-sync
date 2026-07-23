-- regression tests for reported sync bugs
-- each test encodes the *correct* behaviour; failing ones reproduce an open bug
local expect = require '@test/expect'
local mock = require '@test/mock'
local sm = require '@test/sync_mock'
local sync = require '@lib/sync'

local HASH_A = string.rep('a', 64)
local opts = sm.DEFAULT_OPTS

local run = {}

-- issue 1: creating a place must not leak universe_id/place_id into the `input` block.
-- symptom: state file shows place_id/universe_id nested under `input` (and duplicated at top level).
function run.place_create_does_not_leak_identity_into_input()
	local input = sm.make_place_input { file = 'game.rbxl', asset_file = sm.make_asset_file(HASH_A) }

	-- mirror the real open-cloud create: it returns only the new identity
	local api: sync.place_api = {
		create = function(create_opts)
			return { universe_id = create_opts.universe_id, place_id = sm.PLACE_ID } :: any
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

	local api: sync.cloud_api = {
		create = function()
			return sm.make_product_read {} -- carries universe_id + product_id
		end,
		get = mock.never_called 'get',
		update = mock.never_called 'update',
	}

	local lock = sync.await_reconcile_product(api, sm.make_product(input), opts)

	expect.eq(lock.product_id, sm.PRODUCT_ID)
	expect.falsy((lock.input :: any).product_id, 'product_id must not leak into the input block')
	expect.falsy((lock.input :: any).universe_id, 'universe_id must not leak into the input block')
end

return run
