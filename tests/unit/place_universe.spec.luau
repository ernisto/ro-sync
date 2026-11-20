local expect = require '@test/expect'
local mock = require '@test/mock'
local sm = require '@test/sync_mock'
local sync = require '@lib/sync'

local base = require '@lib/resources/base'
local place_configuration = require '@lib/resources/place_configuration'
local universe_configuration = require '@lib/resources/universe_configuration'

local HASH_A = string.rep('a', 64)
local HASH_B = string.rep('b', 64)

local opts = sm.DEFAULT_OPTS

-- tests
local run = {}

function run.place_pushes_settings_change()
	local input = sm.make_place_input { display_name = 'New Name' }
	local prev = sm.make_place_lock(sm.make_place_input())

	local api = sm.make_place_api()

	sync.await_reconcile(api, sm.make_place(input, prev), opts)

	expect.eq(api.update.call_count, 1)
	expect.eq(api.update.calls[1][3].display_name, 'New Name')
end

function run.place_skips_when_unchanged()
	local input = sm.make_place_input()
	local prev = sm.make_place_lock(sm.make_place_input())

	local api = sm.make_place_api(nil, { 'create', 'get', 'update' })

	sync.await_reconcile(api, sm.make_place(input, prev), opts)
end

function run.place_records_settings_conflict()
	local input = sm.make_place_input { display_name = 'Local Name' }
	local prev = sm.make_place_lock(sm.make_place_input())

	local api = sm.make_place_api { display_name = 'Cloud Name' }

	sync.await_reconcile(api, sm.make_place(input, prev), opts)
	expect.truthy(input.conflicts.display_name, 'display_name conflict should be recorded')
end

function run.place_creates_when_no_lock()
	local file = sm.make_asset_file(HASH_A)
	local input = sm.make_place_input { file = 'game.rbxl', asset_file = file }

	local api = sm.make_place_api(nil, { 'get', 'update' })
	api.create = mock.fn(function(_, opts, place)
		return {
			universe_id = opts.universe_id,
			place_id = sm.PLACE_ID,
			input = {
				display_name = place.display_name,
				description = place.description,
				server_size = place.server_size,
				asset_file = { hash = place.asset_file.hash },
			},
		}
	end)

	local lock = sync.await_reconcile(api, sm.make_place(input, nil), opts)

	expect.eq(api.create.call_count, 1)
	expect.eq(lock.place_id, sm.PLACE_ID)

	local asset_file = assert(lock.input.asset_file, 'lock should keep the asset_file')
	expect.eq(asset_file.hash, HASH_A)
	expect.falsy(asset_file.content, 'lock should not retain the uploaded file content')
end

function run.place_creates_without_file()
	local input = sm.make_place_input()

	local api = sm.make_place_api(nil, { 'get', 'update' })
	api.create = mock.fn(function(_, opts)
		return { universe_id = opts.universe_id, place_id = sm.PLACE_ID, input = {} }
	end)

	local lock = sync.await_reconcile(api, sm.make_place(input, nil), opts)
	expect.eq(api.create.call_count, 1)
	expect.eq(lock.place_id, sm.PLACE_ID)
end

function run.place_file_pushed_when_hash_differs()
	local new_file = sm.make_asset_file(HASH_B)
	local input = sm.make_place_input { file = 'game.rbxl', asset_file = new_file }
	local prev = sm.make_place_lock(sm.make_place_input { asset_file = sm.make_asset_file(HASH_A) })

	local api = sm.make_place_api()

	sync.await_reconcile(api, sm.make_place(input, prev), opts)
	expect.eq(api.update.calls[1][3].asset_file, new_file)
end

function run.place_file_noop_when_hash_matches()
	local input = sm.make_place_input { file = 'game.rbxl', asset_file = sm.make_asset_file(HASH_A) }
	local prev = sm.make_place_lock(sm.make_place_input { asset_file = sm.make_asset_file(HASH_A) })

	local api = sm.make_place_api(nil, { 'create', 'get', 'update' })

	sync.await_reconcile(api, sm.make_place(input, prev), opts)
end

function run.place_file_never_conflicts()
	local new_file = sm.make_asset_file(HASH_B)
	local input = sm.make_place_input { file = 'game.rbxl', asset_file = new_file }
	local prev = sm.make_place_lock(sm.make_place_input { asset_file = sm.make_asset_file(HASH_A) })

	local api = sm.make_place_api { description = 'Cloud edit' }

	sync.await_reconcile(api, sm.make_place(input, prev), opts)

	expect.falsy(next(input.conflicts), 'file vs settings should not conflict')
	expect.eq(api.update.calls[1][3].asset_file, new_file) -- file still pushed
	expect.eq(input.description, 'Cloud edit') -- cloud settings pulled in
end

function run.universe_pushes_flag_change()
	local input = sm.make_universe_input { desktop = false }
	local prev = sm.make_universe_lock(sm.make_universe_input())

	local api = sm.make_universe_api()

	sync.await_reconcile(api, sm.make_universe(input, prev), opts)
	expect.eq(api.update.calls[1][3].desktop, false)
end

function run.universe_detects_social_link_change()
	local input = sm.make_universe_input { discord = { uri = 'https://discord.gg/x' } }
	local prev = sm.make_universe_lock(sm.make_universe_input())

	local api = sm.make_universe_api()

	sync.await_reconcile(api, sm.make_universe(input, prev), opts)
	expect.eq(api.update.calls[1][3].discord.uri, 'https://discord.gg/x')
end

function run.universe_records_conflict()
	local input = sm.make_universe_input { private_server_price = 100 }
	local prev = sm.make_universe_lock(sm.make_universe_input())

	local api = sm.make_universe_api { private_server_price = 200 }

	sync.await_reconcile(api, sm.make_universe(input, prev), opts)
	expect.truthy(input.conflicts.private_server_price, 'price conflict should be recorded')
end

function run.universe_baselines_from_cloud_without_lock()
	local input = sm.make_universe_input { desktop = false }

	local api = sm.make_universe_api()

	local lock = sync.await_reconcile(api, sm.make_universe(input, nil), opts)

	expect.eq(lock.universe_id, sm.UNIVERSE_ID)
	expect.eq(api.update.calls[1][3].desktop, false) -- manifest change pushed against pulled baseline
end

function run.unsupported_create_still_baselines_from_cloud()
	local api = sm.make_universe_api()
	api.create = base.unsupported 'no create'

	local lock = sync.await_reconcile(api, sm.make_universe(sm.make_universe_input(), nil), opts)

	expect.eq(lock.universe_id, sm.UNIVERSE_ID, 'baselined from get, not created')
	expect.falsy(base.supports(api.create))
	expect.truthy(base.supports(api.get))
end

-- configuration sub-resources
local function universe_config_lock(input: { [string]: any }): any
	return { universe_id = sm.UNIVERSE_ID, input = input }
end

function run.universe_configuration_accepted_push_updates_lock()
	local api = sm.make_configuration_api(universe_configuration, { price = 0 })
	local resource = sm.make_configuration({ price = 100 }, universe_config_lock { price = 0 })

	local lock = sync.await_reconcile(api, resource, opts)
	expect.eq(lock.input.price, 100)
end

function run.universe_configuration_dropped_push_keeps_lock_in_sync()
	local api = sm.make_configuration_api(universe_configuration, { price = 0 })
	local cloud = api.get()
	api.update = mock.fn(function()
		return cloud -- price refused (e.g. not for-sale)
	end)

	local resource = sm.make_configuration({ price = 100 }, universe_config_lock { price = 0 })
	local lock = sync.await_reconcile(api, resource, opts)

	expect.eq(api.update.calls[1][3].price, 100) -- we did push 100
	expect.eq(lock.input.price, 0) -- but lock reflects the dropped result
end

-- no echo from update (returns nothing applied) → lock follows the cloud state
function run.universe_configuration_no_echo_keeps_lock_at_cloud_value()
	local api = sm.make_configuration_api(universe_configuration, { price = 0 })
	api.update = mock.fn(function()
		return {}
	end)

	local resource = sm.make_configuration({ price = 100 }, universe_config_lock { price = 0 })
	expect.eq(sync.await_reconcile(api, resource, opts).input.price, 0)
end

function run.universe_configuration_pushes_avatar_scales()
	local api = sm.make_configuration_api(universe_configuration, {})
	local scales = { height = 1.05, body_type = 0.5 }
	local resource = sm.make_configuration({ avatar_min_scales = scales }, universe_config_lock {})

	sync.await_reconcile(api, resource, opts)
	expect.eq(api.update.calls[1][3].avatar_min_scales, scales)
end

-- place: cloud drops a refused setting → lock follows the applied result
function run.place_configuration_dropped_push_keeps_lock_in_sync()
	local api = sm.make_configuration_api(place_configuration, { allow_copying = false })
	local cloud = api.get()
	api.update = mock.fn(function()
		return cloud -- refused
	end)

	local prev = { universe_id = sm.UNIVERSE_ID, place_id = sm.PLACE_ID, input = { allow_copying = false } }
	local lock = sync.await_reconcile(api, sm.make_configuration({ allow_copying = true }, prev), opts)

	expect.eq(api.update.calls[1][3].allow_copying, true) -- pushed true
	expect.eq(lock.input.allow_copying, false) -- but cloud kept false
end

-- no lock yet: baseline from cloud at the parent's identity, keep that identity in the new lock
function run.place_configuration_baselines_at_parent_path()
	local api = sm.make_configuration_api(place_configuration, { allow_copying = false })
	local path = { universe_id = sm.UNIVERSE_ID, place_id = sm.PLACE_ID }

	local lock = sync.await_reconcile(api, sm.make_configuration({ allow_copying = true }, nil, path), opts)

	expect.eq(api.get.calls[1][2], path)
	expect.eq(lock.place_id, sm.PLACE_ID)
	expect.eq(api.update.calls[1][3].allow_copying, true)
end

-- mapping
function run.configuration_maps_nested_fields_to_api()
	local patch = {
		avatar_min_scales = { body_type = 0.5 },
		permissions = { client_teleport_allowed = false },
	}
	local api = base.to_api(universe_configuration.FIELDS, patch)

	expect.eq(api.universeAvatarMinScales.bodyType, 0.5)
	expect.eq(api.permissions.IsClientTeleportAllowed, false)
	expect.eq(base.from_api(universe_configuration.FIELDS, api).avatar_min_scales.body_type, 0.5)
end

function run.avatar_overrides_keyed_by_asset_type()
	local overrides = { face = { asset_id = 7, player_choice = true }, asset_type_99 = { asset_id = 8 } }

	local api
	local confirmed = mock.with_http(function(_, _, body)
		api = body
		return body -- PATCH echoes the applied fields
	end, function()
		local patch: any = { avatar_asset_overrides = overrides, conflicts = {} }
		return universe_configuration.update(nil :: any, { universe_id = sm.UNIVERSE_ID }, patch)
	end)

	local by_type = {}
	for _, o in api.universeAvatarAssetOverrides do
		by_type[o.assetTypeID] = o
	end
	expect.eq(by_type[18].assetID, 7)
	expect.eq(by_type[18].isPlayerChoice, true)
	expect.eq(by_type[99].isPlayerChoice, false)

	local back = confirmed.avatar_asset_overrides
	expect.eq(back.face.asset_id, 7)
	expect.eq(back.asset_type_99.asset_id, 8)

	expect.falsy(pcall(function()
		universe_configuration.parse_input({ avatar_asset_overrides = { hat = { asset_id = 1 } } }, 'c')
	end))
end

function run.universe_configuration_reads_studio_access_from_get()
	local read = mock.with_http(function()
		return { isStudioAccessToApisAllowed = true }
	end, function()
		return universe_configuration.get(nil :: any, { universe_id = sm.UNIVERSE_ID })
	end)
	expect.eq(read.studio_access_to_apis_allowed, true)
end

return run
