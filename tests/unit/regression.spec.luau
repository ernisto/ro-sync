-- regression tests for reported sync bugs
-- each test encodes the *correct* behaviour; failing ones reproduce an open bug
local expect = require '@test/expect'
local http = require '@utils/http'
local place_res = require '@lib/resources/place'
local sm = require '@test/sync_mock'
local state = require '@lib/state'
local sync = require '@lib/sync'

local HASH_A = string.rep('a', 64)
local HASH_B = string.rep('b', 64)
local opts = sm.DEFAULT_OPTS

local run = {}

-- issue 1: creating a place must not leak universe_id/place_id into the `input` block.
-- symptom: state file shows place_id/universe_id nested under `input` (and duplicated at top level).
function run.place_create_does_not_leak_identity_into_input()
	local input = sm.make_place_input { file = 'game.rbxl', asset_file = sm.make_asset_file(HASH_A) }

	local api = sm.make_place_api(nil, { 'get', 'update' })
	api.create = function(_, create_opts, place)
		return {
			universe_id = create_opts.universe_id,
			place_id = sm.PLACE_ID,
			input = { display_name = place.display_name, asset_file = { hash = (place.asset_file :: any).hash } },
		} :: any
	end

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
	local api = sm.make_product_api(nil, { 'get', 'update' })
	api.create = function(_, create_opts)
		return {
			universe_id = create_opts.universe_id,
			product_id = sm.PRODUCT_ID,
			input = { name = 'Pack' },
		} :: any
	end

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
	local api = sm.make_place_api(nil, { 'get', 'update' })
	-- mirror the cli create: it pushes config + rbxl via update and echoes the applied place
	api.create = function(_, create_opts, place)
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
		}
	end

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

-- issue 2 (diff sanity): equal gear lists never diff regardless of instance/order.
function run.gear_types_equal_lists_do_not_diff()
	local a = { allowed_gear_types = { 'A', 'B' }, display_name = 'X' }
	local b = { allowed_gear_types = { 'A', 'B' }, display_name = 'X' }
	expect.falsy(next(state.diff_place(a, b)), 'equal gear lists must produce no diff')
end

-- issue 4: a failing place asset upload must not hold back the settings push.
-- the settings PATCH succeeds on the cloud, so sync must record them in the lock and retry
-- only the asset on the next run - instead of treating the whole update as failed (while
-- still reporting both fields as pushed).
function run.place_asset_upload_failure_does_not_hold_settings()
	local new_file = sm.make_asset_file(HASH_B)
	local input = sm.make_place_input { file = 'game.rbxl', display_name = 'New Name', asset_file = new_file }
	local prev = sm.make_place_lock(sm.make_place_input { asset_file = sm.make_asset_file(HASH_A) })

	-- mirrors utils/http semantics: ok responses yield the body, failures surface as errors
	local real_request = http.request
	http.request = function(method, path): any
		local response: any
		if path == 'develop.roblox.com/v2/places/4000' then
			if method == 'GET' then
				-- cloud state matches the lock baseline
				response = { ok = true, body = { name = 'Start', description = 'A place', maxPlayerCount = 50 } }
			else
				expect.eq(method, 'PATCH')
				-- settings PATCH succeeds; cloud echoes the applied config
				response = { ok = true, body = { name = 'New Name', description = 'A place', maxPlayerCount = 50 } }
			end
		elseif string.find(path, '/places/4000/versions$') then
			expect.eq(method, 'POST')
			response = { ok = false, code = 500, message = 'upload failed' }
		else
			error(`unexpected request: {method} {path}`, 0)
		end

		if not response.ok then error(response.message, 0) end
		return response.body
	end

	local ok, lock = pcall(sync.await_reconcile_place, place_res, sm.make_place(input, prev), opts)
	http.request = real_request
	assert(ok, lock)

	expect.eq(lock.input.display_name, 'New Name', 'applied settings must be recorded in the lock')
	local asset = lock.input.asset_file
	expect.truthy(asset == nil or asset.hash ~= HASH_B, 'failed asset upload must not be recorded as pushed')
end

return { run = run }
