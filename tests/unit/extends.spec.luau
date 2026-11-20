local expect = require '@test/expect'
local fs = require '@lune/fs'

local state = require '@lib/state'
local state_fs = require '@cli/state_fs'

local TMP = 'tests/unit/tmp_extends'

local function resources_of(lock: state.lock): any
	return state.build_resources(state.create_input { group = 1 } :: any, lock)
end

local run = {}

function run.extends_any_field_and_keeps_fields_owned_by_others()
	fs.writeDir(TMP)
	fs.writeFile(
		`{TMP}/shared.yml`,
		table.concat({
			'version: 1',
			'products: { other: { universe_id: 1, product_id: 5, input: { name: o } } }',
			'configs: { a: { universe_id: 7, input: { type: json } } }',
		}, '\n')
	)
	fs.writeFile(
		`{TMP}/state.yml`,
		table.concat({
			'version: 1',
			'universe_id: 7',
			`extends: \{ file: {TMP}/shared.yml }`,
			'products: { mine: { universe_id: 7, product_id: 6, input: { name: m } } }',
		}, '\n')
	)

	local lock = state_fs.load_lock(`{TMP}/state.yml`)
	state_fs.await_load_extends(lock)
	local configs, products = lock.configs.a, lock.products

	lock.configs.b = { universe_id = 7, input = { type = 'string' } } :: any
	state_fs.save_resources(resources_of(lock), `{TMP}/cloud.yml`, `{TMP}/state.yml`)

	local shared = state.parse_lock(buffer.fromstring(fs.readFile(`{TMP}/shared.yml`)))
	local own = state.parse_lock(buffer.fromstring(fs.readFile(`{TMP}/state.yml`)))
	fs.removeDir(TMP)

	expect.truthy(configs ~= nil, 'non-owned fields load from the extension')
	expect.eq(products.mine.product_id, 6, 'owned fields stay local')
	expect.eq(products.other, nil)
	expect.truthy(shared.configs.b ~= nil, 'new entries of extended fields go to the extension')
	expect.eq(shared.products.other.product_id, 5, 'extension keeps fields it holds for other states')
	expect.eq(next(own.configs), nil)
	expect.eq(own.products.mine.product_id, 6)
end

return run
