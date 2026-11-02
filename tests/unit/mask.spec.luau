-- import masking: keep every field the user wrote (like sync); the cloud read only goes to the lock
local expect = require '@test/expect'
local sm = require '@test/sync_mock'
local state = require '@lib/state'

local run = {}

-- products
function run.mask_product_keeps_diverging_field()
	local read = sm.make_product_read {}
	local input = sm.make_input { name = 'Local' }

	local out = state.mask_product(read, input)
	expect.eq(out.name, 'Local')
end

function run.mask_product_keeps_field_matching_read()
	local read = sm.make_product_read {}
	local input = sm.make_input { name = 'Local' }

	local out = state.mask_product(read, input)
	expect.eq(out.price, input.price)
	expect.eq(out.description, input.description)
end

function run.mask_product_preserves_conflicts_icon_addons()
	local read = sm.make_product_read {}
	local input = sm.make_input { icon = 'icon.png', addons = { foo = 1 }, conflicts = { name = 'x' } }

	local out = state.mask_product(read, input)
	expect.eq(out.icon, 'icon.png')
	expect.eq(assert(out.addons).foo, 1)
	expect.eq(out.conflicts.name, 'x')
end

function run.mask_product_defaults_conflicts()
	local read = sm.make_product_read {}
	local input: any = sm.make_input {}
	input.conflicts = nil

	local out = state.mask_product(read, input)
	expect.truthy(out.conflicts)
end

-- places
function run.mask_place_keeps_diverging_and_matching()
	local read = sm.place_mirror(sm.make_place_input())
	local input = sm.make_place_input { display_name = 'Local' }

	local out = state.mask_place(read, input)
	expect.eq(out.display_name, 'Local')
	expect.eq(out.server_size, input.server_size)
end

function run.mask_place_preserves_conflicts_and_file()
	local read = sm.place_mirror(sm.make_place_input())
	local input = sm.make_place_input { file = 'game.rbxl', conflicts = { display_name = 'x' } }

	local out = state.mask_place(read, input)
	expect.eq(out.file, 'game.rbxl')
	expect.eq(out.conflicts.display_name, 'x')
end

-- universe
function run.mask_universe_keeps_diverging_and_matching()
	local read = sm.universe_mirror(sm.make_universe_input())
	local input = sm.make_universe_input { desktop = false }

	local out = state.mask_universe(read, input)
	expect.eq(out.desktop, false)
	expect.eq(out.mobile, input.mobile)
	expect.eq(out.private_server_price, input.private_server_price)
end

function run.mask_universe_preserves_conflicts()
	local read = sm.universe_mirror(sm.make_universe_input())
	local input = sm.make_universe_input { conflicts = { desktop = 'x' } }

	local out = state.mask_universe(read, input)
	expect.eq(out.conflicts.desktop, 'x')
end

return run
