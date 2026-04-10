local expect = require '@test/expect'
local mock = require '@test/mock'
local sm = require '@test/sync_mock'
local sync = require '@lib/sync'

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
local cloud_mirror = sm.cloud_mirror

local run = {}

function run.should_create_product_when_no_prev_lock()
	local input = make_input()
	local created: any = nil

	local api: sync.cloud_api = {
		create = function(_, data)
			created = data
			return { universe_id = UNIVERSE_ID, product_id = PRODUCT_ID, name = data.name }
		end,
		get = mock.never_called 'get should not be called on create',
		update = mock.never_called 'update should not be called on create',
	}

	local lock = sync.sync_product(api, make_product(input), opts)

	expect.truthy(created, 'api.create was not called')
	expect.eq(lock.product_id, PRODUCT_ID)
	expect.eq(lock.universe_id, UNIVERSE_ID)
end

function run.should_skip_api_when_input_unchanged()
	local input = make_input()
	local prev = make_lock(table.clone(input))

	local api: sync.cloud_api = {
		create = mock.never_called 'create',
		get = mock.never_called 'get should not be called when nothing changed',
		update = mock.never_called 'update',
	}

	local result = sync.sync_product(api, make_product(input, prev), opts)
	expect.eq(result, prev)
end

function run.should_push_local_changes_to_cloud()
	local original_input = make_input()
	local prev = make_lock(table.clone(original_input))
	local new_input = make_input { name = 'New Name', price = 200 }
	local update = mock.fn()

	local api: sync.cloud_api = {
		create = mock.never_called 'create',
		get = function()
			return cloud_mirror(original_input)
		end,
		update = update,
	}

	sync.sync_product(api, make_product(new_input, prev), opts)

	expect.eq(update.call_count, 1)
	local patch = update.calls[1][2]
	expect.eq(patch.name, 'New Name')
	expect.eq(patch.price, 200)
end

function run.should_pull_cloud_changes_into_input()
	local input = make_input()
	local prev = make_lock(table.clone(input))

	local api: sync.cloud_api = {
		create = mock.never_called 'create',
		get = function()
			return cloud_mirror(make_input { description = 'Dashboard edit' })
		end,
		update = function() end,
	}

	local force_opts = table.clone(opts) :: sync.sync_opts
	force_opts.force_fresh_state = true

	sync.sync_product(api, make_product(input, prev), force_opts)

	expect.eq(input.description, 'Dashboard edit')
end

function run.should_record_conflict_when_both_sides_change_same_field()
	local original_input = make_input()
	local prev = make_lock(table.clone(original_input))
	local new_input = make_input { name = 'Local Name' }

	local api: sync.cloud_api = {
		create = mock.never_called 'create',
		get = function()
			return cloud_mirror(make_input { name = 'Cloud Name' })
		end,
		update = function() end,
	}

	sync.sync_product(api, make_product(new_input, prev), opts)

	expect.truthy(new_input.conflicts, 'conflicts should be recorded')
	expect.truthy(new_input.conflicts.name, 'name conflict should be recorded')
end

function run.should_not_push_fields_listed_in_conflicts()
	local original_input = make_input()
	local prev = make_lock(table.clone(original_input))
	local new_input = make_input { name = 'Local Name', conflicts = { name = 'Cloud Name' } }
	local update = mock.fn()

	local api: sync.cloud_api = {
		create = mock.never_called 'create',
		get = function()
			return cloud_mirror(make_input { name = 'Cloud Name' })
		end,
		update = update,
	}

	sync.sync_product(api, make_product(new_input, prev), opts)

	local patch = update.calls[1] and update.calls[1][2]
	expect.falsy(patch and patch.name, 'conflicted field should not be pushed')
end

-- icon tests
function run.icon_create_saves_assetid_from_result_and_hash_from_input()
	local input = make_input { icon = make_icon_input(ICON_HASH_A) }

	local api: sync.cloud_api = {
		create = function(_, data)
			return { universe_id = UNIVERSE_ID, product_id = PRODUCT_ID, icon = { assetid = ICON_ID }, name = data.name }
		end,
		get = mock.never_called 'get',
		update = mock.never_called 'update',
	}

	local lock = sync.sync_product(api, make_product(input), opts)

	expect.eq(lock.input.icon.assetid, ICON_ID)
	expect.eq(lock.input.icon.hash, ICON_HASH_A)
end

function run.icon_create_preserves_hash_when_result_has_no_icon()
	local input = make_input { icon = make_icon_input(ICON_HASH_A) }

	local api: sync.cloud_api = {
		create = function(_, data)
			return { universe_id = UNIVERSE_ID, product_id = PRODUCT_ID, icon = nil, name = data.name }
		end,
		get = mock.never_called 'get',
		update = mock.never_called 'update',
	}

	local lock = sync.sync_product(api, make_product(input), opts)

	expect.eq(lock.input.icon.hash, ICON_HASH_A)
end

function run.icon_not_pushed_when_hash_matches_lock()
	local input = make_input { icon = make_icon_input(ICON_HASH_A) }
	local prev = make_lock(make_input { icon = make_icon_lock(ICON_ID, ICON_HASH_A) })

	local api: sync.cloud_api = {
		create = mock.never_called 'create',
		get = mock.never_called 'get',
		update = mock.never_called 'update',
	}

	sync.sync_product(api, make_product(input, prev), opts)
end

function run.icon_pushed_when_hash_differs_from_lock()
	local new_icon = make_icon_input(ICON_HASH_B)
	local input = make_input { icon = new_icon }
	local prev = make_lock(make_input { icon = make_icon_lock(ICON_ID, ICON_HASH_A) })
	local update = mock.fn()

	local api: sync.cloud_api = {
		create = mock.never_called 'create',
		get = function()
			return cloud_mirror(make_input { icon = make_icon_lock(ICON_ID, nil) })
		end,
		update = update,
	}

	sync.sync_product(api, make_product(input, prev), opts)

	expect.eq(update.calls[1][2].icon, new_icon)
end

function run.icon_lock_updated_to_new_icon_after_push()
	local new_icon = make_icon_input(ICON_HASH_B)
	local input = make_input { icon = new_icon }
	local prev = make_lock(make_input { icon = make_icon_lock(ICON_ID, ICON_HASH_A) })

	local api: sync.cloud_api = {
		create = mock.never_called 'create',
		get = function()
			return cloud_mirror(make_input { icon = make_icon_lock(ICON_ID, nil) })
		end,
		update = function() end,
	}

	sync.sync_product(api, make_product(input, prev), opts)

	-- lock icon updated so next run detects no hash change
	expect.eq(prev.input.icon, new_icon)
end

function run.icon_pushed_when_lock_has_no_hash()
	-- lock has only assetid (e.g. imported via detect-new), no hash baseline
	local input = make_input { icon = make_icon_input(ICON_HASH_A) }
	local prev = make_lock(make_input { icon = make_icon_lock(ICON_ID, nil) })
	local update = mock.fn()

	local api: sync.cloud_api = {
		create = mock.never_called 'create',
		get = function()
			return cloud_mirror(make_input { icon = make_icon_lock(ICON_ID, nil) })
		end,
		update = update,
	}

	sync.sync_product(api, make_product(input, prev), opts)

	-- nil hash in lock != local hash → treated as change
	expect.eq(update.call_count, 1) -- icon should be pushed when lock has no hash baseline
end

return run
