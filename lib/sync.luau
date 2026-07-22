local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local tbl = require '@utils/tbl'

local state = require './state'
local sync_logger = require './sync_logger'
local types = require './types'

-- defs
export type sync_opts = { universe_id: number, force_fresh_state: boolean? }
type resource_api = {
	diff: ({ [string]: any }, { [string]: any }) -> { [string]: any },
	get: (any) -> { [string]: any },
	-- may echo back the state the cloud actually applied, so silently-dropped fields can be detected
	update: (any, { [string]: any }) -> { [string]: any }?,
	validate: (({ [string]: any }) -> ())?,
}

export type cloud_api = {
	create: (cloud.universe_identity, state.product_input) -> types.product_read,
	update: (cloud.product_identity, state.product_input) -> (),
	get: (cloud.product_identity) -> types.product_read,
}
export type place_api = {
	create: (sync_opts, state.place_input) -> types.place_read,
	-- returns the settings the cloud actually applied (nil when nothing settable was pushed)
	update: (cloud.place_identity, state.place_input) -> state.place_data?,
	get: (cloud.place_identity) -> state.place_data,
}
export type universe_api = {
	-- returns the settings the cloud actually applied (nil when nothing settable was pushed)
	update: (cloud.universe_identity, state.universe_input) -> state.universe_data?,
	get: (cloud.universe_identity) -> state.universe_data,
}

-- functions
local function reconcile_resource(api: resource_api, key: string, input: any, prev: any, opts: sync_opts)
	local conflicts = input.conflicts
	if api.validate then api.validate(input) end

	local local_changes = api.diff(prev.input, input)
	tbl.subtract(local_changes, conflicts)

	if next(local_changes) == nil and not opts.force_fresh_state then
		sync_logger.noop(key)
		return
	end

	sync_logger.update(key, prev.input, local_changes)

	local current = api.get(prev)
	local receiving_changes = api.diff(prev.input, current)
	local sending_changes = tbl.changes(receiving_changes, local_changes)

	tbl.apply(conflicts, tbl.intersection(receiving_changes, sending_changes))
	sync_logger.print_external_changes(prev.input, receiving_changes, conflicts)

	-- resolve
	local free_sending = tbl.subtraction(sending_changes, conflicts)
	local free_receiving = tbl.subtraction(receiving_changes, conflicts)

	-- push
	local pushed_state: { [string]: any }? = nil
	local successfully_pushed, applied = true, nil

	if next(free_sending) then
		successfully_pushed, applied = ctx_log.pcall(api.update, prev, free_sending)
	end
	if successfully_pushed then
		-- optimistically record the pushed values into the lock; echo (if any) corrects dropped fields below
		tbl.apply(prev.input, free_sending)
		if type(applied) == 'table' then pushed_state = applied end
	end

	-- save
	tbl.apply(prev.input, receiving_changes)
	tbl.apply(input, tbl.intersection(free_receiving, input))

	-- the cloud can silently drop a pushed field (e.g. price while not for-sale); when update echoes the
	-- applied state, reconcile lock.input to what actually landed instead of the value we optimistically set
	local dropped = if pushed_state then tbl.intersection(api.diff(prev.input, pushed_state), free_sending) else {}
	tbl.apply(prev.input, dropped)

	sync_logger.print_pushed_changes(free_sending)
	sync_logger.print_dropped_changes(dropped)
	sync_logger.update_result(successfully_pushed, free_sending, conflicts)
end

local function await_create_product(api: cloud_api, product: state.product, opts: sync_opts): state.product_lock
	local key, input = product.key, product.input
	sync_logger.creation(key)

	local success, result = ctx_log.pcall(api.create, opts, input)
	sync_logger.print_pushed_changes(tbl.subtraction(input, { addons = true, conflicts = true }))
	sync_logger.creation_result(success)

	local saved_icon =
		{ assetid = result.icon_file and result.icon_file.assetid, hash = input.icon_file and input.icon_file.hash }
	tbl.apply(result, { icon_file = saved_icon })

	return { universe_id = result.universe_id, product_id = result.product_id, input = result }
end
local function await_reconcile_product(api: cloud_api, product: state.product, opts: sync_opts): state.product_lock
	local prev = product.lock
	if not prev then return await_create_product(api, product, opts) end

	local function validate(input)
		if input.icon and not input.icon_file then ctx_log.warn(`couldnt find icon '{input.icon}'`) end
	end

	local api_impl = { diff = state.diff_product, get = api.get, update = api.update, validate = validate }
	reconcile_resource(api_impl, product.key, product.input, prev, opts)

	return prev
end

local function await_create_place(api: place_api, place: state.place, opts: sync_opts): state.place_lock
	local key, input = place.key, place.input
	sync_logger.creation(key)

	if not input.display_name then
		ctx_log.error(`place '{key}' needs a display_name to be created`)
		sync_logger.creation_result(false)
		error(`place '{key}' needs a display_name to be created`)
	end
	if not input.asset_file then
		local missing = if input.file then `file '{input.file}' not found` else 'no file set'

		ctx_log.error(`place '{key}' has {missing}; a .rbxl file is required to create a place`)
		sync_logger.creation_result(false)
		error(`place '{key}' has {missing}; a .rbxl file is required to create a place`)
	end

	local success, result = ctx_log.pcall(api.create, opts, input)
	sync_logger.print_pushed_changes(tbl.subtraction(input, { file = true, conflicts = true }))
	sync_logger.creation_result(success)

	tbl.apply(result, { asset_file = { hash = input.asset_file.hash } })
	return { universe_id = result.universe_id, place_id = result.place_id, input = result }
end
local function await_reconcile_place(api: place_api, place: state.place, opts: sync_opts): state.place_lock
	local prev = place.lock
	if not prev then return await_create_place(api, place, opts) end

	local function validate(input)
		if input.file and not input.asset_file then ctx_log.warn(`couldnt find place file '{input.file}'`) end
	end

	local api_impl = { diff = state.diff_place, get = api.get, update = api.update, validate = validate }
	reconcile_resource(api_impl, place.key, place.input, prev, opts)

	return prev
end

local function await_reconcile_universe(
	api: universe_api,
	universe: state.universe,
	opts: sync_opts
): state.universe_lock
	local prev = universe.lock or { universe_id = opts.universe_id, input = api.get { universe_id = opts.universe_id } }

	local api_impl = { diff = state.diff_universe, get = api.get, update = api.update }
	reconcile_resource(api_impl, universe.key, universe.input, prev, opts)

	return prev
end

-- module
return table.freeze {
	await_reconcile_product = await_reconcile_product,
	await_reconcile_place = await_reconcile_place,
	await_reconcile_universe = await_reconcile_universe,
}
