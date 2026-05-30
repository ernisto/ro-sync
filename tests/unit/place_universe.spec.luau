local expect = require '@test/expect'
local mock = require '@test/mock'
local sm = require '@test/sync_mock'
local sync = require '@lib/sync'

local HASH_A = string.rep('a', 64)
local HASH_B = string.rep('b', 64)

local opts = sm.DEFAULT_OPTS

local run = {}

-- ── places: settings ──────────────────────────────────────────────────────────

function run.place_pushes_settings_change()
	local input = sm.make_place_input { display_name = 'New Name' }
	local prev = sm.make_place_lock(sm.make_place_input())
	local update = mock.fn()

	local api: sync.place_api = {
		get = function()
			return sm.place_mirror(sm.make_place_input())
		end,
		update = update,
	}

	sync.await_reconcile_place(api, sm.make_place(input, prev), opts)

	expect.eq(update.call_count, 1)
	expect.eq(update.calls[1][2].display_name, 'New Name')
end

function run.place_skips_when_unchanged()
	local input = sm.make_place_input()
	local prev = sm.make_place_lock(sm.make_place_input())

	local api: sync.place_api = {
		get = mock.never_called 'get should not be called when nothing changed',
		update = mock.never_called 'update',
	}

	sync.await_reconcile_place(api, sm.make_place(input, prev), opts)
end

function run.place_records_settings_conflict()
	local input = sm.make_place_input { display_name = 'Local Name' }
	local prev = sm.make_place_lock(sm.make_place_input())

	local api: sync.place_api = {
		get = function()
			return sm.place_mirror(sm.make_place_input { display_name = 'Cloud Name' })
		end,
		update = function() end,
	}

	sync.await_reconcile_place(api, sm.make_place(input, prev), opts)
	expect.truthy(input.conflicts.display_name, 'display_name conflict should be recorded')
end

function run.place_errors_without_lock()
	local input = sm.make_place_input()
	local api: sync.place_api = {
		get = mock.never_called 'get',
		update = mock.never_called 'update',
	}

	local ok = pcall(sync.await_reconcile_place, api, sm.make_place(input, nil), opts)
	expect.falsy(ok, 'syncing a place with no lock should error')
end

-- ── places: file asset (push-only) ─────────────────────────────────────────────

function run.place_file_pushed_when_hash_differs()
	local new_file = sm.make_asset_file(HASH_B)
	local input = sm.make_place_input { file = 'game.rbxl', asset_file = new_file }
	local prev = sm.make_place_lock(sm.make_place_input { asset_file = sm.make_asset_file(HASH_A) })
	local update = mock.fn()

	local api: sync.place_api = {
		get = function()
			return sm.place_mirror(sm.make_place_input())
		end,
		update = update,
	}

	sync.await_reconcile_place(api, sm.make_place(input, prev), opts)
	expect.eq(update.calls[1][2].asset_file, new_file)
end

function run.place_file_noop_when_hash_matches()
	local input = sm.make_place_input { file = 'game.rbxl', asset_file = sm.make_asset_file(HASH_A) }
	local prev = sm.make_place_lock(sm.make_place_input { asset_file = sm.make_asset_file(HASH_A) })

	local api: sync.place_api = {
		get = mock.never_called 'get should not be called when file unchanged',
		update = mock.never_called 'update',
	}

	sync.await_reconcile_place(api, sm.make_place(input, prev), opts)
end

-- file change never conflicts with a concurrent cloud settings change
function run.place_file_never_conflicts()
	local new_file = sm.make_asset_file(HASH_B)
	local input = sm.make_place_input { file = 'game.rbxl', asset_file = new_file }
	local prev = sm.make_place_lock(sm.make_place_input { asset_file = sm.make_asset_file(HASH_A) })
	local update = mock.fn()

	local api: sync.place_api = {
		get = function()
			return sm.place_mirror(sm.make_place_input { description = 'Cloud edit' })
		end,
		update = update,
	}

	sync.await_reconcile_place(api, sm.make_place(input, prev), opts)

	expect.falsy(next(input.conflicts), 'file vs settings should not conflict')
	expect.eq(update.calls[1][2].asset_file, new_file) -- file still pushed
	expect.eq(input.description, 'Cloud edit') -- cloud settings pulled in
end

-- ── universe settings ──────────────────────────────────────────────────────────

function run.universe_pushes_flag_change()
	local input = sm.make_universe_input { desktop = false }
	local prev = sm.make_universe_lock(sm.make_universe_input())
	local update = mock.fn()

	local api: sync.universe_api = {
		get = function()
			return sm.universe_mirror(sm.make_universe_input())
		end,
		update = update,
	}

	sync.await_reconcile_universe(api, sm.make_universe(input, prev), opts)
	expect.eq(update.calls[1][2].desktop, false)
end

function run.universe_detects_social_link_change()
	local input = sm.make_universe_input { discord = { uri = 'https://discord.gg/x' } }
	local prev = sm.make_universe_lock(sm.make_universe_input())
	local update = mock.fn()

	local api: sync.universe_api = {
		get = function()
			return sm.universe_mirror(sm.make_universe_input())
		end,
		update = update,
	}

	sync.await_reconcile_universe(api, sm.make_universe(input, prev), opts)
	expect.eq(update.calls[1][2].discord.uri, 'https://discord.gg/x')
end

function run.universe_pulls_external_change()
	local input = sm.make_universe_input()
	local prev = sm.make_universe_lock(sm.make_universe_input())

	local api: sync.universe_api = {
		get = function()
			return sm.universe_mirror(sm.make_universe_input { private_server_price = 100 })
		end,
		update = function() end,
	}

	local force = table.clone(opts) :: sync.sync_opts
	force.force_fresh_state = true

	sync.await_reconcile_universe(api, sm.make_universe(input, prev), force)
	expect.eq(input.private_server_price, 100)
end

function run.universe_records_conflict()
	local input = sm.make_universe_input { private_server_price = 100 }
	local prev = sm.make_universe_lock(sm.make_universe_input())

	local api: sync.universe_api = {
		get = function()
			return sm.universe_mirror(sm.make_universe_input { private_server_price = 200 })
		end,
		update = function() end,
	}

	sync.await_reconcile_universe(api, sm.make_universe(input, prev), opts)
	expect.truthy(input.conflicts.private_server_price, 'price conflict should be recorded')
end

function run.universe_baselines_from_cloud_without_lock()
	local input = sm.make_universe_input { desktop = false }
	local update = mock.fn()

	local api: sync.universe_api = {
		get = function()
			return sm.universe_mirror(sm.make_universe_input())
		end,
		update = update,
	}

	local lock = sync.await_reconcile_universe(api, sm.make_universe(input, nil), opts)

	expect.eq(lock.universe_id, sm.UNIVERSE_ID)
	expect.eq(update.calls[1][2].desktop, false) -- manifest change pushed against pulled baseline
end

return run
