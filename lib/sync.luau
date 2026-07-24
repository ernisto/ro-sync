local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local tbl = require '@utils/tbl'

local state = require './state'
local sync_logger = require './sync_logger'
local types = require './types'

-- defs
export type sync_opts = { universe_id: number, force_fresh_state: boolean?, overwrite: boolean? }
type resource_lock = { universe_id: number, input: { [string]: any } }
type resource_api = {
	diff: ({ [string]: any }, { [string]: any }) -> { [string]: any },
	get: (any) -> { [string]: any },
	update: (any, { [string]: any }) -> { [string]: any }?,
	create: ((sync_opts, any) -> resource_lock)?,
	validate: (({ [string]: any }) -> ())?,
}

export type product_api = {
	create: (sync_opts, state.product_input) -> state.product_lock,
	update: (cloud.product_identity, state.product_input) -> (),
	get: (cloud.product_identity) -> types.product_read,
}
export type place_api = {
	create: (sync_opts, state.place_input) -> state.place_lock,
	update: (cloud.place_identity, state.place_input) -> state.place_data?,
	get: (cloud.place_identity) -> state.place_data,
}
export type universe_api = {
	update: (cloud.universe_identity, state.universe_input) -> state.universe_data?,
	get: (cloud.universe_identity) -> state.universe_data,
}

-- functions
local function reconcile_resource<Lock>(
	api: resource_api,
	key: string,
	input: any,
	prev: (Lock & resource_lock)?,
	opts: sync_opts
): Lock
	if api.validate then api.validate(input) end

	if not prev then
		sync_logger.creation(key)
		local create = api.create or error 'resource has no create'

		local ok, created_lock = ctx_log.pcall(create, opts, input)
		if ok then sync_logger.print_pushed_changes(api.diff({}, created_lock.input)) end

		sync_logger.creation_result(ok)
		assert(ok, created_lock)
		return created_lock :: any
	end

	local conflicts = input.conflicts
	if opts.overwrite then table.clear(conflicts) end

	local local_changes = api.diff(prev.input, input)
	tbl.subtract(local_changes, conflicts)

	if next(local_changes) == nil and not opts.force_fresh_state then
		sync_logger.noop(key)
		return prev
	end

	sync_logger.update(key, prev.input, local_changes)

	local current = api.get(prev)
	local receiving_changes = api.diff(prev.input, current)
	local sending_changes = tbl.changes(receiving_changes, local_changes)

	if not opts.overwrite then tbl.apply(conflicts, tbl.intersection(receiving_changes, sending_changes)) end
	sync_logger.print_external_changes(prev.input, receiving_changes, conflicts)

	-- resolve
	local free_sending = tbl.subtraction(sending_changes, conflicts)
	local free_receiving = tbl.subtraction(receiving_changes, sending_changes)

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
	tbl.apply(prev.input, tbl.subtraction(receiving_changes, free_sending))
	tbl.apply(input, tbl.intersection(free_receiving, input))

	-- the cloud can silently drop a pushed field (e.g. price while not for-sale); when update echoes the
	-- applied state, reconcile lock.input to what actually landed instead of the value we optimistically set
	local dropped = if pushed_state then tbl.intersection(api.diff(prev.input, pushed_state), free_sending) else {}
	tbl.apply(prev.input, dropped)

	sync_logger.print_pushed_changes(free_sending)
	sync_logger.print_dropped_changes(dropped)
	sync_logger.update_result(successfully_pushed, free_sending, conflicts)

	return prev
end

local function await_reconcile_product(api: product_api, product: state.product, opts: sync_opts): state.product_lock
	local prev = product.lock

	local function validate(input)
		if input.icon and not input.icon_file then ctx_log.warn(`couldnt find icon '{input.icon}'`) end
	end

	local api_impl =
		{ diff = state.diff_product, get = api.get, update = api.update, create = api.create, validate = validate }
	return reconcile_resource(api_impl :: any, product.key, product.input, prev, opts)
end

local function await_reconcile_place(api: place_api, place: state.place, opts: sync_opts): state.place_lock
	local prev = place.lock

	local function validate(input)
		if input.file and not input.asset_file then ctx_log.warn(`couldnt find place file '{input.file}'`) end
	end

	local api_impl =
		{ diff = state.diff_place, get = api.get, update = api.update, create = api.create, validate = validate }
	return reconcile_resource(api_impl :: any, place.key, place.input, prev, opts)
end

local function await_reconcile_universe(
	api: universe_api,
	universe: state.universe,
	opts: sync_opts
): state.universe_lock
	local prev = universe.lock or { universe_id = opts.universe_id, input = api.get { universe_id = opts.universe_id } }

	local api_impl = { diff = state.diff_universe, get = api.get, update = api.update }
	return reconcile_resource(api_impl, universe.key, universe.input, prev, opts)
end

-- module
return table.freeze {
	await_reconcile_product = await_reconcile_product,
	await_reconcile_place = await_reconcile_place,
	await_reconcile_universe = await_reconcile_universe,
}
