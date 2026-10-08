local ctx_log = require '@utils/ctx_log'
local tbl = require '@utils/tbl'

local base = require './resources/base'
local pass = require './resources/pass'
local place = require './resources/place'
local product = require './resources/product'
local thumbnail = require './resources/thumbnail'
local universe = require './resources/universe'

local state = require './state'
local sync_logger = require './sync_logger'

-- defs
type thumbnail_api = typeof(thumbnail)
type universe_api = typeof(universe)
type product_api = typeof(product)
type place_api = typeof(place)
type pass_api = typeof(pass)

export type sync_opts = {
	universe_id: number,
	ignore_cloud: boolean?,
	overwrite: boolean?,
	sync_all: boolean?,
	session: base.session,
}

type resource<Lock = any> = {
	key: string,
	lock: (Lock & resource_lock)??,
	input: { [string]: any, conflicts: { [string]: any } },
}

type resource_lock = { universe_id: number, input: { [string]: any } }
type resource_api = {
	diff: ({ [string]: any }, { [string]: any }) -> { [string]: any },
	get: (any, any) -> { [string]: any }?,
	update: (any, any, { [string]: any }) -> ({ [string]: any }, string?),
	create: ((any, sync_opts, any) -> resource_lock)?,
	validate: (({ [string]: any }) -> ())?,
}

-- functions
local function reconcile_resource<Lock>(api: resource_api, resource: resource<Lock>, opts: sync_opts): Lock
	local key, input, prev = resource.key, resource.input, resource.lock
	if api.validate then api.validate(input) end

	if not prev then
		sync_logger.creation(key)
		local create = api.create or error 'resource has no create'

		local ok, created_lock = ctx_log.pcall(create, opts.session, opts, input)
		if ok then sync_logger.print_pushed_changes(api.diff({}, created_lock.input)) end

		sync_logger.creation_result(ok)
		assert(ok, created_lock)
		return created_lock :: any
	end

	-- guard
	local local_changes = api.diff(prev.input, input)

	if next(local_changes) == nil and not opts.sync_all then
		sync_logger.noop(key)
		return prev
	end

	sync_logger.update(key, prev.input, local_changes)

	-- refresh state
	local cloud_state = if opts.ignore_cloud then prev.input else api.get(opts.session, prev) or {}
	local receiving_changes = api.diff(prev.input, cloud_state)
	local sending_changes = tbl.intersection(api.diff(cloud_state, input), local_changes)

	sync_logger.print_external_changes(prev.input, receiving_changes)
	tbl.apply(prev.input, cloud_state)

	-- conflicts
	local conflicts = input.conflicts
	local conflicted_changes = {}

	-- local auto_solved = tbl.intersection(matched, conflicts)
	-- sync_logger.solved_conflicts(auto_solved)

	local matched = tbl.subtraction(cloud_state, sending_changes)
	tbl.subtract(conflicts, matched)

	if opts.overwrite then
		tbl.subtract(conflicts, sending_changes)
	else
		conflicted_changes = tbl.intersection(sending_changes, receiving_changes)
		tbl.apply(conflicts, conflicted_changes)
	end

	-- push
	local free_sending = tbl.subtraction(sending_changes, conflicts)
	local expected = tbl.applied(cloud_state, free_sending)

	local confirmed_state, push_err = cloud_state, nil
	if next(free_sending) then
		confirmed_state, push_err = api.update(opts.session, prev, free_sending)
	end

	confirmed_state = tbl.applied(cloud_state, confirmed_state)
	tbl.apply(prev.input, confirmed_state)

	local confirmed_received = tbl.subtraction(confirmed_state, conflicted_changes)
	tbl.apply(input, tbl.intersection(confirmed_received, input))

	local dropped = api.diff(expected, confirmed_state)
	local applied = api.diff(cloud_state, confirmed_state)

	tbl.apply(applied, conflicts)
	tbl.apply(applied, dropped)

	sync_logger.print_pushed_changes(applied, conflicts, dropped)
	sync_logger.update_result(push_err == nil, free_sending, conflicts)

	return prev
end

local function await_reconcile_product(api: product_api, product: state.product, opts: sync_opts): product.product_lock
	local function validate(input)
		if input.icon and not input.icon_file then ctx_log.warn(`couldnt find icon '{input.icon}'`) end
	end

	local api_impl =
		{ diff = state.diff_product, get = api.get, update = api.update, create = api.create, validate = validate }
	return reconcile_resource(api_impl :: any, product :: any, opts)
end

local function await_reconcile_place(api: place_api, place: state.place, opts: sync_opts): place.place_lock
	local function validate(input)
		if input.file and not input.asset_file then ctx_log.warn(`couldnt find place file '{input.file}'`) end
	end

	local api_impl =
		{ diff = state.diff_place, get = api.get, update = api.update, create = api.create, validate = validate }
	return reconcile_resource(api_impl :: any, place :: any, opts)
end

local function await_reconcile_pass(api: pass_api, pass: state.pass, opts: sync_opts): pass.pass_lock
	local function validate(input)
		if input.icon and not input.icon_file then ctx_log.warn(`couldnt find icon '{input.icon}'`) end
	end

	local api_impl =
		{ diff = state.diff_pass, get = api.get, update = api.update, create = api.create, validate = validate }
	return reconcile_resource(api_impl :: any, pass :: any, opts)
end

local function await_reconcile_thumbnail(
	api: thumbnail_api,
	thumbnail: state.thumbnail,
	opts: sync_opts
): thumbnail.thumbnail_lock
	local function validate(input)
		if input.file and not input.image_file then ctx_log.warn(`couldnt find thumbnail '{input.file}'`) end
	end

	local api_impl =
		{ diff = state.diff_thumbnail, get = api.get, update = api.update, create = api.create, validate = validate }
	return reconcile_resource(api_impl :: any, thumbnail :: any, opts)
end

local function await_reconcile_universe(
	api: universe_api,
	universe: state.universe,
	opts: sync_opts
): universe.universe_lock
	universe.lock = universe.lock
		or { universe_id = opts.universe_id, input = api.get(opts.session, { universe_id = opts.universe_id }) }

	local api_impl = { diff = state.diff_universe, get = api.get, update = api.update }
	return reconcile_resource(api_impl :: any, universe, opts)
end

-- module
return table.freeze {
	await_reconcile_thumbnail = await_reconcile_thumbnail,
	await_reconcile_universe = await_reconcile_universe,
	await_reconcile_product = await_reconcile_product,
	await_reconcile_place = await_reconcile_place,
	await_reconcile_pass = await_reconcile_pass,
}
