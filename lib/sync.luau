local ctx_log = require '@utils/ctx_log'
local tbl = require '@utils/tbl'

local place = require './resources/place'
local product = require './resources/product'
local universe = require './resources/universe'

local state = require './state'
local sync_logger = require './sync_logger'

-- defs
export type sync_opts = { universe_id: number, overwrite: boolean?, fresh_state: boolean? }
type resource_lock = { universe_id: number, input: { [string]: any } }
type resource_api = {
	diff: ({ [string]: any }, { [string]: any }) -> { [string]: any },
	get: (any) -> { [string]: any }?,
	update: (any, { [string]: any }) -> ({ [string]: any }, string?),
	create: ((sync_opts, any) -> resource_lock)?,
	validate: (({ [string]: any }) -> ())?,
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

	-- guard
	local local_changes = api.diff(prev.input, input)

	if next(local_changes) == nil and not opts.fresh_state then
		sync_logger.noop(key)
		return prev
	end

	sync_logger.update(key, prev.input, local_changes)

	-- refresh state
	local cloud_state = if opts.overwrite then prev.input else api.get(prev) or {}
	local receiving_changes = api.diff(prev.input, cloud_state)
	local sending_changes = tbl.intersection(api.diff(cloud_state, input), local_changes)

	sync_logger.print_external_changes(prev.input, receiving_changes)
	tbl.apply(prev.input, cloud_state)

	-- conflicts
	local conflicts = input.conflicts
	if opts.overwrite then table.clear(conflicts) end

	-- local auto_solved = tbl.intersection(matched, conflicts)
	-- sync_logger.solved_conflicts(auto_solved)

	local matched = tbl.subtraction(cloud_state, sending_changes)
	tbl.subtract(conflicts, matched)

	local conflicted_changes = tbl.intersection(sending_changes, receiving_changes)
	tbl.apply(conflicts, conflicted_changes)

	local free_sending = tbl.subtraction(sending_changes, conflicts)
	local free_received = tbl.subtraction(receiving_changes, conflicted_changes)

	-- push
	local confirmed_state, push_err = cloud_state, nil
	if next(free_sending) then
		confirmed_state, push_err = api.update(prev, free_sending)
	end

	confirmed_state = tbl.applied(cloud_state, confirmed_state)
	local expected = tbl.applied(cloud_state, free_sending)

	tbl.apply(prev.input, confirmed_state)
	tbl.apply(input, tbl.intersection(free_received, input))

	local dropped = api.diff(expected, confirmed_state)
	local applied = api.diff(cloud_state, confirmed_state)

	tbl.apply(applied, conflicts)
	tbl.apply(applied, dropped)

	sync_logger.print_pushed_changes(applied, conflicts, dropped)
	sync_logger.update_result(push_err == nil, free_sending, conflicts)

	return prev
end

local function await_reconcile_product(api: product.api, product: state.product, opts: sync_opts): product.product_lock
	local prev = product.lock

	local function validate(input)
		if input.icon and not input.icon_file then ctx_log.warn(`couldnt find icon '{input.icon}'`) end
	end

	local api_impl =
		{ diff = state.diff_product, get = api.get, update = api.update, create = api.create, validate = validate }
	return reconcile_resource(api_impl :: any, product.key, product.input, prev, opts)
end

local function await_reconcile_place(api: place.api, place: state.place, opts: sync_opts): place.place_lock
	local prev = place.lock

	local function validate(input)
		if input.file and not input.asset_file then ctx_log.warn(`couldnt find place file '{input.file}'`) end
	end

	local api_impl =
		{ diff = state.diff_place, get = api.get, update = api.update, create = api.create, validate = validate }
	return reconcile_resource(api_impl :: any, place.key, place.input, prev, opts)
end

local function await_reconcile_universe(
	api: universe.api,
	universe: state.universe,
	opts: sync_opts
): universe.universe_lock
	local prev = universe.lock or { universe_id = opts.universe_id, input = api.get { universe_id = opts.universe_id } }

	local api_impl = { diff = state.diff_universe, get = api.get, update = api.update }
	return reconcile_resource(api_impl :: any, universe.key, universe.input, prev, opts)
end

-- module
return table.freeze {
	await_reconcile_product = await_reconcile_product,
	await_reconcile_place = await_reconcile_place,
	await_reconcile_universe = await_reconcile_universe,
}
