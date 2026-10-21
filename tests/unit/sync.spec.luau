local expect = require '@test/expect'
local sm = require '@test/sync_mock'
local sync = require '@lib/sync'

-- defs
local ICON_HASH_A = string.rep('a', 64)
local ICON_HASH_B = string.rep('b', 64)

local UNIVERSE_ID = sm.UNIVERSE_ID
local PRODUCT_ID = sm.PRODUCT_ID
local ICON_ID = sm.ICON_ID

local opts = sm.DEFAULT_OPTS
local make_input = sm.make_input
local make_lock = sm.make_lock
local make_product = sm.make_product
local make_icon_input = sm.make_icon_input
local make_icon_lock = sm.make_icon_lock

-- tests
local run = {}

function run.should_create_product_when_no_prev_lock()
	local input = make_input()
	local created: any = nil

	local api = sm.make_product_api(nil, { 'get', 'update' })
	api.create = function(_, _, data)
		created = data
		return { universe_id = UNIVERSE_ID, product_id = PRODUCT_ID, input = { name = data.name } } :: any
	end

	local lock = sync.await_reconcile(api, make_product(input), opts)

	expect.truthy(created, 'api.create was not called')
	expect.eq(lock.product_id, PRODUCT_ID)
	expect.eq(lock.universe_id, UNIVERSE_ID)
end

function run.should_skip_api_when_input_unchanged()
	local input = make_input()
	local prev = make_lock(table.clone(input))

	local api = sm.make_product_api(nil, { 'create', 'get', 'update' })

	local result = sync.await_reconcile(api, make_product(input, prev), opts)
	expect.eq(result, prev)
end

function run.should_push_local_changes_to_cloud()
	local original_input = make_input()
	local prev = make_lock(table.clone(original_input))
	local new_input = make_input { name = 'New Name', price = 200 }

	local api = sm.make_product_api()

	sync.await_reconcile(api, make_product(new_input, prev), opts)

	expect.eq(api.update.call_count, 1)
	local patch = api.update.calls[1][3]
	expect.eq(patch.name, 'New Name')
	expect.eq(patch.price, 200)
end

function run.should_record_conflict_when_both_sides_change_same_field()
	local original_input = make_input()
	local prev = make_lock(table.clone(original_input))
	local new_input = make_input { name = 'Local Name' }

	local api = sm.make_product_api { name = 'Cloud Name' }

	sync.await_reconcile(api, make_product(new_input, prev), opts)

	expect.truthy(new_input.conflicts, 'conflicts should be recorded')
	expect.truthy(new_input.conflicts.name, 'name conflict should be recorded')
end

function run.should_not_push_fields_listed_in_conflicts()
	local original_input = make_input()
	local prev = make_lock(table.clone(original_input))
	local new_input = make_input { name = 'Local Name', conflicts = { name = 'Cloud Name' } }

	local api = sm.make_product_api { name = 'Cloud Name' }

	sync.await_reconcile(api, make_product(new_input, prev), opts)

	local patch = api.update.calls[1] and api.update.calls[1][3]
	expect.falsy(patch and patch.name, 'conflicted field should not be pushed')
end

function run.should_not_pull_new_fields_into_input()
	-- manifest + lock share a baseline that never declares `store_page_enabled`
	local input = make_input { name = 'Local Name' }
	local prev = make_lock(make_input())

	-- cloud changed an existing field (description) AND exposes an untracked field
	local api = sm.make_product_api { description = 'Dashboard edit', store_page_enabled = true }

	sync.await_reconcile(api, make_product(input, prev), opts)

	-- modified existing field is pulled back into the manifest
	expect.eq(input.description, 'Dashboard edit')
	-- field never declared in the manifest must NOT be introduced
	expect.eq(input.store_page_enabled, nil)
end

-- icon tests
function run.icon_not_pushed_when_hash_matches_lock()
	local input = make_input { icon_file = make_icon_input(ICON_HASH_A) }
	local prev = make_lock(make_input { icon_file = make_icon_lock(ICON_ID, ICON_HASH_A) })

	local api = sm.make_product_api(nil, { 'create', 'get', 'update' })

	sync.await_reconcile(api, make_product(input, prev), opts)
end

function run.icon_pushed_when_hash_differs_from_lock()
	local new_icon = make_icon_input(ICON_HASH_B)
	local input = make_input { icon_file = new_icon }
	local prev = make_lock(make_input { icon_file = make_icon_lock(ICON_ID, ICON_HASH_A) })

	local api = sm.make_product_api { icon = make_icon_lock(ICON_ID, nil) }

	sync.await_reconcile(api, make_product(input, prev), opts)

	expect.eq(api.update.calls[1][3].icon_file, new_icon)
end

function run.icon_lock_updated_to_new_icon_after_push()
	local new_icon = make_icon_input(ICON_HASH_B)
	local input = make_input { icon_file = new_icon }
	local prev = make_lock(make_input { icon_file = make_icon_lock(ICON_ID, ICON_HASH_A) })

	local api = sm.make_product_api { icon = make_icon_lock(ICON_ID, nil) }

	sync.await_reconcile(api, make_product(input, prev), opts)

	-- lock icon updated so next run detects no hash change
	expect.eq(prev.input.icon_file.hash, ICON_HASH_B)
end

function run.icon_pushed_when_lock_has_no_hash()
	-- lock has only assetid (e.g. imported via detect-new), no hash baseline
	local input = make_input { icon_file = make_icon_input(ICON_HASH_A) }
	local prev = make_lock(make_input { icon_file = make_icon_lock(ICON_ID, nil) })

	local api = sm.make_product_api { icon = make_icon_lock(ICON_ID, nil) }

	sync.await_reconcile(api, make_product(input, prev), opts)

	-- nil hash in lock != local hash → treated as change
	expect.eq(api.update.call_count, 1) -- icon should be pushed when lock has no hash baseline
end

function run.snapshot_detects_conflicts_after_scan()
	local snapshot = make_input()
	local prev = make_lock(make_input { name = 'Cloud Name', price = 300 })
	prev.input.conflicts = nil
	local input = make_input { name = 'Local Name' }

	local api = sm.make_product_api({ name = 'Cloud Name', price = 300 }, { 'create' })
	sync.await_reconcile(api, make_product(input, prev), opts, make_lock(snapshot))

	expect.eq(input.conflicts.name, 'Local Name')
	expect.eq(input.price, 300)
	expect.eq(api.update.call_count, 0)
end

return run
