local ctx_log = require '@utils/ctx_log'
local tbl = require '@utils/tbl'

local base = require './resources/base'
local icon = require './resources/icon'
local pass = require './resources/pass'
local place = require './resources/place'
local product = require './resources/product'
local thumbnail = require './resources/thumbnail'
local universe = require './resources/universe'

local state = require './state'
local sync_logger = require './sync_logger'

-- defs
type thumbnail_api = typeof(thumbnail)
type icon_api = typeof(icon)
type universe_api = typeof(universe)
type product_api = typeof(product)
type place_api = typeof(place)
type pass_api = typeof(pass)

export type sync_opts = {
	session: base.session,
	ignore_cloud: boolean?,
	overwrite: boolean?,
	sync_all: boolean?,
}

export type sync_ctx = {
	session: base.session,
	universe_id: number,
	ignore_cloud: boolean?,
	overwrite: boolean?,
	sync_all: boolean?,
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
	create: ((any, sync_ctx, any) -> resource_lock)?,
	validate: (({ [string]: any }) -> ())?,
}

-- functions
local function reconcile_resource<Lock>(api: resource_api, resource: resource<Lock>, opts: sync_ctx): Lock
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

local function await_reconcile_product(api: product_api, product: state.product, opts: sync_ctx): product.product_lock
	local function validate(input)
		if input.icon and not input.icon_file then ctx_log.warn(`couldnt find icon '{input.icon}'`) end
	end

	local api_impl =
		{ diff = state.diff_product, get = api.get, update = api.update, create = api.create, validate = validate }
	return reconcile_resource(api_impl :: any, product :: any, opts)
end

local function await_reconcile_place(api: place_api, place: state.place, opts: sync_ctx): place.place_lock
	local function validate(input)
		if input.file and not input.asset_file then ctx_log.warn(`couldnt find place file '{input.file}'`) end
	end

	local api_impl =
		{ diff = state.diff_place, get = api.get, update = api.update, create = api.create, validate = validate }
	return reconcile_resource(api_impl :: any, place :: any, opts)
end

local function await_reconcile_pass(api: pass_api, pass: state.pass, opts: sync_ctx): pass.pass_lock
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
	opts: sync_ctx
): thumbnail.thumbnail_lock
	local function validate(input)
		if input.file and not input.image_file then ctx_log.warn(`couldnt find thumbnail '{input.file}'`) end
	end

	local api_impl =
		{ diff = state.diff_thumbnail, get = api.get, update = api.update, create = api.create, validate = validate }
	return reconcile_resource(api_impl :: any, thumbnail :: any, opts)
end

local function await_reconcile_icon(api: icon_api, icon: state.icon, opts: sync_ctx): icon.icon_lock
	local function validate(input)
		if input.file and not input.image_file then ctx_log.warn(`couldnt find icon '{input.file}'`) end
	end

	local api_impl =
		{ diff = state.diff_icon, get = api.get, update = api.update, create = api.create, validate = validate }
	return reconcile_resource(api_impl :: any, icon :: any, opts)
end

local function await_reconcile_universe(
	api: universe_api,
	universe: state.universe,
	opts: sync_ctx
): universe.universe_lock
	universe.lock = universe.lock
		or { universe_id = opts.universe_id, input = api.get(opts.session, { universe_id = opts.universe_id }) }

	local api_impl = { diff = state.diff_universe, get = api.get, update = api.update }
	return reconcile_resource(api_impl :: any, universe, opts)
end

local function await_reconcile_thumbnails(session: base.session, resources: state.resources)
	local kept = {}
	for _, resource in resources.thumbnails do
		local file = resource.lock and resource.lock.input.image_file
		if file then kept[file.hash] = true end
	end

	for hash, lock in resources.lock.thumbnails do
		if kept[hash] then continue end
		local ok, err = pcall(thumbnail.delete, session, lock)
		if ok then
			resources.lock.thumbnails[hash] = nil
			ctx_log.str(`deleted thumbnail {lock.thumbnail_id}`)
		else
			ctx_log.warn(`couldnt delete thumbnail {lock.thumbnail_id}: {err}`)
		end
	end

	if #resources.thumbnails > 0 then
		local ids = {}
		for _, resource in resources.thumbnails do
			if resource.lock then table.insert(ids, resource.lock.thumbnail_id) end
		end
		local ok, err = pcall(thumbnail.reorder, session, resources.lock.universe_id, ids)
		if not ok then ctx_log.warn(`couldnt reorder thumbnails: {err}`) end
	end
end

local function await_reconcile_all(resources: state.resources, opts: sync_opts)
	local ctx: sync_ctx = table.clone(opts :: any)
	ctx.universe_id = resources.lock.universe_id

	if resources.universe then resources.universe.lock = await_reconcile_universe(universe, resources.universe, ctx) end
	if resources.icon then resources.icon.lock = await_reconcile_icon(icon, resources.icon, ctx) end
	if resources.manifest.thumbnails then await_reconcile_thumbnails(ctx.session, resources) end

	for _, resource in resources.thumbnails do
		resource.lock = await_reconcile_thumbnail(thumbnail, resource, ctx)
	end
	for _, resource in resources.products do
		resource.lock = await_reconcile_product(product, resource, ctx)
	end
	for _, resource in resources.places do
		resource.lock = await_reconcile_place(place, resource, ctx)
	end
	for _, resource in resources.passes do
		resource.lock = await_reconcile_pass(pass, resource, ctx)
	end
end

-- module
return table.freeze {
	await_reconcile_thumbnail = await_reconcile_thumbnail,
	await_reconcile_icon = await_reconcile_icon,
	await_reconcile_universe = await_reconcile_universe,
	await_reconcile_product = await_reconcile_product,
	await_reconcile_place = await_reconcile_place,
	await_reconcile_pass = await_reconcile_pass,
	await_reconcile_all = await_reconcile_all,
}
