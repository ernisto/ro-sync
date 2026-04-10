local expect = require '@test/expect'
local sync = require '@lib/sync'

local run = {}

-- helpers

local UNIVERSE_ID = 1000
local PRODUCT_ID = 2000
local ICON_ID = 3000
local ICON_HASH_A = string.rep('a', 64)
local ICON_HASH_B = string.rep('b', 64)

local opts: sync.sync_opts = { universe_id = UNIVERSE_ID, force_fresh_state = false }

local function make_input(overrides: { [string]: any }?): any
	local base = { name = 'Pack', price = 100, description = 'A pack', is_for_sale = true }
	if overrides then
		for k, v in overrides do
			base[k] = v
		end
	end
	return base
end

local function make_lock(input: any): any
	return { universe_id = UNIVERSE_ID, product_id = PRODUCT_ID, input = input }
end

local function make_icon_input(hash: string): any
	return { hash = hash, content = buffer.create(0) }
end

local function make_icon_lock(assetid: number, hash: string?): any
	return { assetid = assetid, hash = hash }
end

local function cloud_mirror(input: any): any
	local icon_id = type(input.icon) == 'table' and (input.icon :: any).assetid or nil
	return {
		universe_id = UNIVERSE_ID,
		product_id = PRODUCT_ID,
		icon = if icon_id then { assetid = icon_id } else nil,
		name = input.name,
		price = input.price,
		description = input.description,
		is_for_sale = input.is_for_sale,
		regional_pricing = input.regional_pricing,
		store_page_enabled = input.store_page_enabled,
	}
end

local function make_product(input: any, lock: any?): any
	return { key = 'key', input = input, lock = lock }
end

-- tests

function run.should_create_product_when_no_prev_lock()
	local input = make_input()
	local created: any = nil

	local api: sync.cloud_api = {
		create = function(_, data)
			created = data
			return { universe_id = UNIVERSE_ID, product_id = PRODUCT_ID, name = data.name }
		end,
		get = expect.never_called 'get should not be called on create',
		update = expect.never_called 'update should not be called on create',
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
		create = expect.never_called 'create',
		get = expect.never_called 'get should not be called when nothing changed',
		update = expect.never_called 'update',
	}

	local result = sync.sync_product(api, make_product(input, prev), opts)
	expect.eq(result, prev)
end

function run.should_push_local_changes_to_cloud()
	local original_input = make_input()
	local prev = make_lock(table.clone(original_input))
	local new_input = make_input { name = 'New Name', price = 200 }
	local updated_patch: any = nil

	local api: sync.cloud_api = {
		create = expect.never_called 'create',
		get = function() return cloud_mirror(original_input) end,
		update = function(_, patch) updated_patch = patch end,
	}

	sync.sync_product(api, make_product(new_input, prev), opts)

	expect.truthy(updated_patch, 'api.update was not called')
	expect.eq(updated_patch.name, 'New Name')
	expect.eq(updated_patch.price, 200)
end

function run.should_pull_cloud_changes_into_input()
	local input = make_input()
	local prev = make_lock(table.clone(input))

	local api: sync.cloud_api = {
		create = expect.never_called 'create',
		get = function() return cloud_mirror(make_input { description = 'Dashboard edit' }) end,
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
		create = expect.never_called 'create',
		get = function() return cloud_mirror(make_input { name = 'Cloud Name' }) end,
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
	local updated_patch: any = nil

	local api: sync.cloud_api = {
		create = expect.never_called 'create',
		get = function() return cloud_mirror(make_input { name = 'Cloud Name' }) end,
		update = function(_, patch) updated_patch = patch end,
	}

	sync.sync_product(api, make_product(new_input, prev), opts)

	expect.falsy(updated_patch and updated_patch.name, 'conflicted field should not be pushed')
end

-- icon tests

function run.icon_create_saves_assetid_from_result_and_hash_from_input()
	local input = make_input { icon = make_icon_input(ICON_HASH_A) }

	local api: sync.cloud_api = {
		create = function(_, data)
			return { universe_id = UNIVERSE_ID, product_id = PRODUCT_ID, icon = { assetid = ICON_ID }, name = data.name }
		end,
		get = expect.never_called 'get',
		update = expect.never_called 'update',
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
		get = expect.never_called 'get',
		update = expect.never_called 'update',
	}

	local lock = sync.sync_product(api, make_product(input), opts)

	expect.eq(lock.input.icon.hash, ICON_HASH_A)
end

function run.icon_not_pushed_when_hash_matches_lock()
	local input = make_input { icon = make_icon_input(ICON_HASH_A) }
	local prev = make_lock(make_input { icon = make_icon_lock(ICON_ID, ICON_HASH_A) })

	local api: sync.cloud_api = {
		create = expect.never_called 'create',
		get = expect.never_called 'get',
		update = expect.never_called 'update',
	}

	sync.sync_product(api, make_product(input, prev), opts)
end

function run.icon_pushed_when_hash_differs_from_lock()
	local new_icon = make_icon_input(ICON_HASH_B)
	local input = make_input { icon = new_icon }
	local prev = make_lock(make_input { icon = make_icon_lock(ICON_ID, ICON_HASH_A) })
	local pushed_icon: any = nil

	local api: sync.cloud_api = {
		create = expect.never_called 'create',
		get = function() return cloud_mirror(make_input { icon = make_icon_lock(ICON_ID, nil) }) end,
		update = function(_, patch) pushed_icon = patch.icon end,
	}

	sync.sync_product(api, make_product(input, prev), opts)

	expect.eq(pushed_icon, new_icon)
end

function run.icon_lock_updated_to_new_icon_after_push()
	local new_icon = make_icon_input(ICON_HASH_B)
	local input = make_input { icon = new_icon }
	local prev = make_lock(make_input { icon = make_icon_lock(ICON_ID, ICON_HASH_A) })

	local api: sync.cloud_api = {
		create = expect.never_called 'create',
		get = function() return cloud_mirror(make_input { icon = make_icon_lock(ICON_ID, nil) }) end,
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
	local update_called = false

	local api: sync.cloud_api = {
		create = expect.never_called 'create',
		get = function() return cloud_mirror(make_input { icon = make_icon_lock(ICON_ID, nil) }) end,
		update = function() update_called = true end,
	}

	sync.sync_product(api, make_product(input, prev), opts)

	-- nil hash in lock != local hash → treated as change
	expect.truthy(update_called, 'icon should be pushed when lock has no hash baseline')
end

return run
