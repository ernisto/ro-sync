local expect = require '@test/expect'
local fs = require '@lune/fs'
local http = require '@utils/http'

local state = require '@lib/state'
local state_fs = require '@cli/state_fs'

local TMP = 'tests/unit/tmp_extends'
local ASSETS: any = { abc = { id = 12, paths = { 'ui/btn.png' } } }

local function lock_with(extends: string): state.lock
	return state.parse_lock(buffer.fromstring(`version: 1\nuniverse_id: 7\nextends: {extends}\n`))
end

local function resources_of(lock: state.lock): any
	return state.build_resources(state.create_input { group = 1 } :: any, lock)
end

local run = {}

function run.file_extends_owns_assets()
	fs.writeDir(TMP)
	local lock = lock_with(`\{ file: {TMP}/assets-state.yml }`)

	state_fs.await_load_extends(lock)
	expect.eq(next(lock.assets :: any), nil, 'missing extended file starts empty')

	lock.assets = ASSETS
	state_fs.save_resources(resources_of(lock), `{TMP}/cloud.yml`, `{TMP}/state.yml`)

	local own = fs.readFile(`{TMP}/state.yml`)
	local reloaded = state_fs.load_lock(`{TMP}/state.yml`)
	state_fs.await_load_extends(reloaded)
	fs.removeDir(TMP)

	expect.eq(string.find(own, 'ui/btn'), nil, 'assets are not duplicated into the extending state')
	expect.eq((reloaded.assets :: any).abc.id, 12)
end

function run.rbxstore_extends_reads_and_writes_entry()
	fs.writeDir(TMP)
	local lock = lock_with '{ rbxstore: { store: rosync, key: assets, universe: 9 } }'
	local calls = {}

	local call = http.call
	http.call = function(endpoint: any, _, path: any, body: any, query: any): any
		table.insert(calls, { method = endpoint.method, path = path, body = body, query = query })
		if endpoint.method == 'GET' then error('404 NOT_FOUND', 0) end
		return {}
	end
	local ok, err = pcall(function()
		state_fs.await_load_extends(lock, {} :: any)
		lock.assets = ASSETS
		state_fs.save_resources(resources_of(lock), `{TMP}/cloud.yml`, `{TMP}/state.yml`, {} :: any)
	end)
	http.call = call
	fs.removeDir(TMP)
	expect.truthy(ok, err)

	expect.eq(calls[1].path.universe_id, 9)
	expect.eq(calls[1].path.data_store_id, 'rosync')
	expect.eq(calls[1].path.entry_id, 'assets')
	expect.eq(calls[2].method, 'PATCH')
	expect.eq(calls[2].query.allowMissing, true)
	expect.eq(calls[2].body.value.assets.abc.id, 12)
end

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
