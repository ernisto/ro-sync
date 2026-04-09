local expect = require '@test/expect'
local sync = require '@lib/sync'

local run = {}

-- helpers

local UNIVERSE_ID = 1000
local PRODUCT_ID = 2000
local ICON_ID = 3000

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

local function make_lock(input: any): sync.product_lock
	return {
		universe_id = UNIVERSE_ID,
		product_id = PRODUCT_ID,
		icon_id = ICON_ID,
		icon_hash = nil,
		input = input,
	}
end

local function cloud_mirror(input: any): any
	-- cloud state that exactly matches the given input
	return {
		universe_id = UNIVERSE_ID,
		product_id = PRODUCT_ID,
		icon_id = ICON_ID,
		name = input.name,
		price = input.price,
		description = input.description,
		is_for_sale = input.is_for_sale,
		regional_pricing = input.regional_pricing,
		store_page_enabled = input.store_page_enabled,
	}
end

-- tests

function run.should_create_product_when_no_prev_lock()
	local input = make_input()
	local created: any = nil

	local api: sync.cloud_api = {
		create = function(universe, data)
			created = data
			return {
				universe_id = UNIVERSE_ID,
				product_id = PRODUCT_ID,
				icon_id = ICON_ID,
				name = data.name,
				price = data.price,
				description = data.description,
				is_for_sale = data.is_for_sale,
			}
		end,
		get = expect.never_called 'get should not be called on create',
		update = expect.never_called 'update should not be called on create',
	}

	local lock = sync.sync_product(api, 'key', input, nil, opts)

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

	local result = sync.sync_product('key', input, prev, api, opts)
	expect.eq(result, prev) -- exact same reference returned
end

function run.should_push_local_changes_to_cloud()
	local original_input = make_input()
	local prev = make_lock(table.clone(original_input))

	local new_input = make_input { name = 'New Name', price = 200 }
	local updated_patch: any = nil

	local api: sync.cloud_api = {
		create = expect.never_called 'create',
		get = function()
			return cloud_mirror(original_input)
		end,
		update = function(_, patch)
			updated_patch = patch
		end,
	}

	sync.sync_product('key', new_input, prev, api, opts)

	expect.truthy(updated_patch, 'api.update was not called')
	expect.eq(updated_patch.name, 'New Name')
	expect.eq(updated_patch.price, 200)
end

function run.should_pull_cloud_changes_into_input()
	local input = make_input()
	local prev = make_lock(table.clone(input))

	-- cloud has a different description (someone edited on the dashboard)
	local api: sync.cloud_api = {
		create = expect.never_called 'create',
		get = function()
			return cloud_mirror(make_input { description = 'Dashboard edit' })
		end,
		update = function() end, -- may or may not be called; we only care about input
	}

	local opts = table.clone(opts) :: sync.sync_opts
	opts.force_fresh_state = true -- force a pull even though local input is same

	sync.sync_product('key', input, prev, api, opts)

	expect.eq(input.description, 'Dashboard edit')
end

function run.should_record_conflict_when_both_sides_change_same_field()
	local original_input = make_input()
	local prev = make_lock(table.clone(original_input))

	-- local changes name
	local new_input = make_input { name = 'Local Name' }

	local api: sync.cloud_api = {
		create = expect.never_called 'create',
		get = function()
			-- cloud also changed name independently
			return cloud_mirror(make_input { name = 'Cloud Name' })
		end,
		update = function() end,
	}

	sync.sync_product('key', new_input, prev, api, opts)

	expect.truthy(new_input.conflicts, 'conflicts should be recorded')
	expect.truthy(new_input.conflicts.name, 'name conflict should be recorded')
end

function run.should_not_push_fields_listed_in_conflicts()
	local original_input = make_input()
	-- prev already has a conflict recorded from a prior run
	local prev = make_lock(table.clone(original_input))

	local new_input = make_input { name = 'Local Name', conflicts = { name = 'Cloud Name' } }
	local updated_patch: any = nil

	local api: sync.cloud_api = {
		create = expect.never_called 'create',
		get = function()
			return cloud_mirror(make_input { name = 'Cloud Name' })
		end,
		update = function(_, patch)
			updated_patch = patch
		end,
	}

	sync.sync_product('key', new_input, prev, api, opts)

	-- name is in conflicts so it should NOT be pushed
	expect.falsy(updated_patch and updated_patch.name, 'conflicted field should not be pushed')
end

return run
