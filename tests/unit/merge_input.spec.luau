local expect = require '@test/expect'
local state_fs = require '@cli/state_fs'

local run = {}

function run.extra_manifests_override_and_restore()
	local base: any = {
		places = { start = { display_name = 'Game' } },
		products = { pack = { name = 'Pack', price = 10 } },
	}
	local overrides: { state_fs.override } = {}
	state_fs.merge_input(base, { places = { start = { display_name = '[DEV] Game', file = 'start.rbxl' } } }, overrides)
	state_fs.merge_input(
		base,
		{ places = { start = { display_name = '[me] Game' }, tests = { file = 'mix.rbxl' } } },
		overrides
	)

	expect.eq(base.places.start.display_name, '[me] Game', 'last manifest wins')
	expect.eq(base.places.start.file, 'start.rbxl')
	expect.eq(base.places.tests.file, 'mix.rbxl')

	base.products.pack.price = 20 -- synced changes outside overrides stay
	state_fs.restore_overrides(base, overrides)

	expect.eq(base.places.start.display_name, 'Game', 'first manifest value back')
	expect.eq(base.places.start.file, nil, 'fields only extras set are dropped')
	expect.eq(base.places.tests, nil, 'entries only extras set are dropped')
	expect.eq(base.products.pack.price, 20)
end

return run
