local expect = require '@test/expect'
local tbl = require '@utils/tbl'

local run = {}

-- tbl.apply / tbl.applied

function run.should_apply_mutations_in_place()
	local base: any = { a = 1, b = 2 }
	local result = tbl.apply(base, { b = 99, c = 3 })
	expect.eq(result, base) -- same reference
	expect.eq(base.b, 99)
	expect.eq(base.c, 3)
end

function run.should_return_new_table_from_applied()
	local base = { a = 1, b = 2 }
	local result = tbl.applied(base, { b = 99 })
	expect.neq(result, base) -- different reference
	expect.eq(result.b, 99)
	expect.eq(base.b, 2) -- original untouched
end

-- tbl.subtract / tbl.subtraction

function run.should_remove_keys_in_place()
	local base = { a = 1, b = 2, c = 3 }
	tbl.subtract(base, { b = true, c = true })
	expect.eq(base.a, 1)
	expect.falsy(base.b, 'b should be removed')
	expect.falsy(base.c, 'c should be removed')
end

function run.should_return_new_table_from_subtraction()
	local base = { a = 1, b = 2 }
	local result = tbl.subtraction(base, { b = true })
	expect.neq(result, base)
	expect.eq(result.a, 1)
	expect.falsy(result.b)
	expect.eq(base.b, 2) -- original untouched
end

-- tbl.changes

function run.should_return_keys_that_differ()
	local from = { a = 1, b = 2, c = 3 }
	local to = { a = 1, b = 99, c = 3, d = 4 }
	local diff = tbl.changes(from, to)
	expect.falsy(diff.a)
	expect.eq(diff.b, 99)
	expect.falsy(diff.c)
	expect.eq(diff.d, 4)
end

function run.should_return_empty_when_tables_are_equal()
	local t = { x = 1, y = 'hello' }
	local diff = tbl.changes(t, { x = 1, y = 'hello' })
	expect.falsy(next(diff))
end

function run.should_not_include_keys_removed_in_to()
	-- changes only captures keys present in `to`; removal is not tracked
	local from = { a = 1, b = 2 }
	local to = { a = 1 } -- b removed
	local diff = tbl.changes(from, to)
	expect.falsy(diff.b)
end

-- tbl.intersection

function run.should_keep_only_keys_present_in_mask()
	local source = { a = 1, b = 2, c = 3 }
	local mask: any = { a = '', c = '' }
	local result = tbl.intersection(source, mask)
	expect.eq(result.a, 1)
	expect.falsy(result.b)
	expect.eq(result.c, 3)
end

function run.should_use_source_values_not_mask_values()
	local source = { x = 42 }
	local mask = { x = 0 }
	local result = tbl.intersection(source, mask)
	expect.eq(result.x, 42)
end

function run.should_return_new_table_from_intersection()
	local source = { a = 1 }
	local mask = { a = '' }
	local result = tbl.intersection(source, mask)
	expect.neq(result, source)
end

return run
