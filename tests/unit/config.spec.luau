local config = require '@lib/resources/config'
local expect = require '@test/expect'
local http = require '@utils/http'
local sm = require '@test/sync_mock'
local state = require '@lib/state'

type call = { method: string, base: string, repository: string?, body: any }

local run = {}

-- stubs `http.call` with a responder keyed by `METHOD base-suffix`, records every call
local function with_cloud(responses: { [string]: any }, fn: () -> ()): { call }
	local calls: { call } = {}
	local real_call = http.call

	http.call = function(endpoint: any, _session, path: any, body): any
		local repository, suffix = path.repository, string.match(endpoint.base, '{repository}(.*)$')
		table.insert(calls, { method = endpoint.method, base = endpoint.base, repository = repository, body = body })
		local response = responses[`{endpoint.method} {suffix or ''}`]

		if response == nil then error(`unexpected request: {endpoint.method} {suffix}`, 0) end
		if type(response) == 'string' then error(response, 0) end
		return response
	end :: any

	local ok, err = pcall(fn :: any)
	http.call = real_call
	assert(ok, err)
	return calls
end

function run.list_infers_type_from_values()
	local reads
	with_cloud({
		['GET /full'] = {
			entries = {
				j = { value = {} },
				s = { value = 'x' },
				n = { value = 1.5 },
				b = { value = true },
				empty = { value = 1, description = '' },
			},
		},
	}, function()
		reads = config.list({} :: any, { universe_id = sm.UNIVERSE_ID })
	end)

	expect.eq(reads.j.type, 'json')
	expect.eq(reads.s.type, 'string')
	expect.eq(reads.n.type, 'number')
	expect.eq(reads.b.type, 'boolean')
	expect.eq(reads.empty.description, nil, 'empty description is unset')
end

function run.rejects_unknown_type()
	expect.falsy(pcall(config.parse_input, { type = 'table' }, 'c'), 'unknown type')
	expect.truthy(pcall(config.parse_input, { type = 'json', description = 'd' }, 'c'))
end

function run.manifest_and_lock_round_trip_configs()
	local manifest = state.parse_manifest(buffer.fromstring [[
version: 1
owner: { user: 1 }
configs:
  skillpoints: { type: json }
]])
	expect.eq(manifest.configs.skillpoints.type, 'json')
	local out = state.encode_manifest(manifest)
	expect.truthy(out:find 'skillpoints', 'config kept')
	expect.falsy(out:find 'conflicts', 'empty conflicts dropped')

	local encoded = state.encode_lock {
		universe_id = sm.UNIVERSE_ID,
		products = {},
		passes = {},
		thumbnails = {},
		places = {},
		configs = { skillpoints = { universe_id = sm.UNIVERSE_ID, key = 'skillpoints', input = { type = 'json' } } },
	}
	expect.falsy(encoded:find("'key'", 1, true), 'key is the map key, not stored')

	local lock = state.parse_lock(buffer.fromstring(encoded))
	expect.eq(lock.configs.skillpoints.key, 'skillpoints', 'key restored from the map key')
	expect.eq(lock.configs.skillpoints.input.type, 'json')
end

function run.create_adopts_existing_key_without_writing()
	local lock
	local calls = with_cloud({
		['GET /full'] = { entries = { skillpoints = { value = { a = 1 }, description = 'tuning' } } },
	}, function()
		lock = config.create(
			{} :: any,
			{ universe_id = sm.UNIVERSE_ID },
			{ type = 'json', conflicts = {} } :: any,
			'skillpoints'
		)
	end)

	expect.eq(#calls, 1, 'only reads')
	expect.eq(lock.key, 'skillpoints')
	expect.eq(lock.input.type, 'json')
	expect.eq(lock.input.description, 'tuning')
end

function run.create_publishes_zero_value_for_missing_key()
	local lock
	local calls = with_cloud({
		['GET /full'] = { entries = {} },
		['GET /draft'] = '404 Not Found',
		['PATCH /draft'] = { draftHash = 'h' },
		['POST /publish'] = { configVersion = 2 },
	}, function()
		lock = config.create(
			{} :: any,
			{ universe_id = sm.UNIVERSE_ID },
			{ type = 'number', conflicts = {} } :: any,
			'speed'
		)
	end)

	expect.eq(calls[3].method, 'PATCH')
	expect.eq(calls[3].body.entries.speed, 0, 'zero value of the type')
	expect.eq(calls[4].body.draftHash, 'h')
	expect.eq(lock.input.type, 'number')
end

function run.create_handles_universe_without_any_config()
	local calls = with_cloud({
		['GET /full'] = '404 Not Found',
		['GET /draft'] = '404 Not Found',
		['PATCH /draft'] = { draftHash = 'h' },
		['POST /publish'] = { configVersion = 1 },
	}, function()
		config.create({} :: any, { universe_id = sm.UNIVERSE_ID }, { type = 'json', conflicts = {} } :: any, 'k')
	end)
	expect.eq(#calls, 4, 'reads treat 404 as empty, then publishes')
	expect.eq(calls[1].repository, 'InExperienceConfig')
end

function run.create_refuses_to_publish_someone_elses_draft()
	local ok = true
	local calls = with_cloud({
		['GET /full'] = { entries = {} },
		['GET /draft'] = { draftHash = 'h', entries = { other = 1 } },
	}, function()
		ok = pcall(
			config.create,
			{} :: any,
			{ universe_id = sm.UNIVERSE_ID },
			{ type = 'json', conflicts = {} } :: any,
			'k'
		)
	end)

	expect.falsy(ok, 'pending draft blocks creation')
	expect.eq(#calls, 2, 'no writes')
end

function run.update_reports_read_only_fields()
	local ok, err = pcall(
		config.update :: any,
		{} :: any,
		{ universe_id = sm.UNIVERSE_ID, key = 'k', input = { type = 'json' } } :: any,
		{ description = 'x', conflicts = {} } :: any
	)
	expect.falsy(ok, 'nothing is pushed')
	expect.truthy(string.find(tostring(err), 'read-only', 1, true), 'explains why')
end

function run.validates_values_against_type()
	expect.falsy(pcall(config.parse_input, { type = 'number', value = 'x' }, 'c'), 'value of the wrong type')
	expect.falsy(pcall(config.parse_input, { type = 'json', value = {}, value_file = 'a.json' }, 'c'), 'both sources')
	expect.truthy(pcall(config.parse_input, { type = 'json', value = { a = 1 } }, 'c'))
	expect.truthy(pcall(config.parse_input, { type = 'string', value_file = 'motd.txt' }, 'c'))
end

function run.value_file_decodes_by_extension()
	local json: any = { type = 'json', value_file = 'a.JSON', conflicts = {} }
	config.load_value_file(json, '{"a":1}', 'c')
	expect.eq(json.value.a, 1)

	local text: any = { type = 'string', value_file = 'motd.txt', conflicts = {} }
	config.load_value_file(text, 'hi', 'c')
	expect.eq(text.value, 'hi')

	local wrong: any = { type = 'number', value_file = 'n.json', conflicts = {} }
	expect.falsy(pcall(config.load_value_file, wrong, '"x"', 'c'), 'decoded value is type checked')
	expect.falsy(
		state
			.encode_manifest(state.parse_manifest(buffer.fromstring [[
version: 1
owner: { user: 1 }
configs:
  motd: { type: string, value_file: motd.txt }
]]))
			:find("'value':", 1, true),
		'value_file values stay in the file'
	)
end

function run.update_publishes_value()
	local confirmed
	local calls = with_cloud({
		['GET /draft'] = '404 Not Found',
		['PATCH /draft'] = { draftHash = 'h' },
		['POST /publish'] = { configVersion = 3 },
	}, function()
		confirmed = config.update(
			{} :: any,
			{ universe_id = sm.UNIVERSE_ID, key = 'speed', input = { type = 'number', value = 1 } } :: any,
			{ value = 2 } :: any
		)
	end)

	expect.eq(calls[2].body.entries.speed, 2)
	expect.eq(calls[3].body.draftHash, 'h')
	expect.eq(confirmed.value, 2)
end

function run.create_publishes_value_over_existing_key()
	local lock
	local calls = with_cloud({
		['GET /full'] = { entries = { speed = { value = 1 } } },
		['GET /draft'] = '404 Not Found',
		['PATCH /draft'] = { draftHash = 'h' },
		['POST /publish'] = { configVersion = 2 },
	}, function()
		lock = config.create(
			{} :: any,
			{ universe_id = sm.UNIVERSE_ID },
			{ type = 'number', value = 5, conflicts = {} } :: any,
			'speed'
		)
	end)

	expect.eq(calls[3].body.entries.speed, 5)
	expect.eq(lock.input.value, 5, 'tracked value kept in the lock')
end

function run.user_data_templates_live_in_data_stores_config()
	local templates =
		{ { key_template = { data_store_type = 'STANDARD', data_store_name = 'players', key_pattern = '{UserId}' } } }
	local calls = with_cloud({
		['GET /full'] = { entries = {} },
		['GET /draft'] = '404 Not Found',
		['PATCH /draft'] = { draftHash = 'h' },
		['POST /publish'] = { configVersion = 1 },
	}, function()
		config.create(
			{} :: any,
			{ universe_id = sm.UNIVERSE_ID },
			{ type = 'json', value = templates, conflicts = {} } :: any,
			'user_data_templates'
		)
	end)

	for _, call in calls do
		expect.eq(call.repository, 'DataStoresConfig')
	end
	expect.eq(calls[3].body.entries.user_data_templates[1].key_template.data_store_name, 'players')
end

local function names_of(input: any): string
	local out = {}
	for _, item in input.value do
		table.insert(out, item.n)
	end
	return table.concat(out, ',')
end

function run.as_array_orders_new_configs_by_name()
	local input: any = { type = 'json', as_array = true, value = { b = { n = 'b' }, a = { n = 'a' } }, conflicts = {} }
	config.arrange(input, nil)
	expect.eq(names_of(input), 'a,b')
	expect.eq(table.concat(input.order, ','), 'a,b')

	config.arrange(input, nil)
	expect.eq(names_of(input), 'a,b', 'arranging twice keeps the map')
end

function run.as_array_keeps_synced_slots_and_appends_new_names()
	local lock: any =
		{ universe_id = 1, key = 'k', input = { type = 'json', value = {} }, order = { 'z', 'gone', 'm' } }
	local value = { m = { n = 'm' }, z = { n = 'z' }, c = { n = 'c' }, b = { n = 'b' } }
	local input: any = { type = 'json', as_array = true, value = value, conflicts = {} }
	config.arrange(input, lock)

	expect.eq(names_of(input), 'z,m,b,c', 'synced order kept, removed dropped, new appended by name')
	expect.eq(table.concat(lock.order, ','), 'z,m,b,c')
end

function run.as_array_matches_slots_by_content_without_order()
	local lock: any = { universe_id = 1, key = 'k', input = { type = 'json', value = { { n = 'y' }, { n = 'x' } } } }
	local value = { x = { n = 'x' }, y = { n = 'y' }, a = { n = 'a' } }
	local input: any = { type = 'json', as_array = true, value = value, conflicts = {} }
	config.arrange(input, lock)

	expect.eq(names_of(input), 'y,x,a')
end

function run.as_array_encodes_the_map_and_locks_the_order()
	local input: any = { type = 'json', as_array = true, value = { a = { n = 'a' } }, conflicts = {} }
	config.arrange(input, nil)
	expect.eq((config.encode_input(input) :: any).value.a.n, 'a', 'manifest keeps the map')
	expect.eq(config.encode_input(input).order, nil)

	local lock: any
	with_cloud({
		['GET /full'] = { entries = {} },
		['GET /draft'] = '404 Not Found',
		['PATCH /draft'] = { draftHash = 'h' },
		['POST /publish'] = { configVersion = 1 },
	}, function()
		lock = config.create({} :: any, { universe_id = sm.UNIVERSE_ID }, input, 'k')
	end)
	expect.eq(lock.input.value[1].n, 'a', 'pushed as an array')
	expect.eq(table.concat(lock.order, ','), 'a')
	expect.eq(config.encode_lock_entry(lock).order[1], 'a')
end

return run
