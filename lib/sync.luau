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
export type sync_opts = {
	session: base.session,
	snapshot: state.lock?, -- lock before any cloud import; defaults to the current lock
	ignore_cloud: boolean?,
	overwrite: boolean?,
}

export type sync_ctx = {
	session: base.session,
	universe_id: number,
	ignore_cloud: boolean?,
	overwrite: boolean?,
}

type resource<Lock = any> = {
	key: string,
	lock: resource_lock?,
	input: { [string]: any, conflicts: { [string]: any } },
}

type resource_lock = { universe_id: number, input: { [string]: any }, [string]: number }
type resource_api = {
	diff: ({ [string]: any }, { [string]: any }) -> { [string]: any },
	get: (any, any) -> { [string]: any }?,
	update: (any, any, { [string]: any }) -> ({ [string]: any }, string?),
	create: ((any, sync_ctx, any) -> resource_lock)?,
	validate: (({ [string]: any }) -> ())?,
}

-- functions
local function await_reconcile<Lock>(res: any, resource: resource<Lock>, opts: sync_ctx, snapshot: resource_lock?): Lock
	local api: resource_api = res

	local key, input, prev = resource.key, resource.input, resource.lock
	if api.validate then api.validate(input) end

	if not prev and not api.create then
		local path = { universe_id = opts.universe_id }
		prev = { universe_id = opts.universe_id, input = api.get(opts.session, path) or {} } :: any
	end

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
	local synced = (snapshot or prev).input
	local local_changes = api.diff(synced, input)

	if next(local_changes) == nil and next(api.diff(synced, prev.input)) == nil then
		sync_logger.noop(key)
		return prev :: any
	end

	sync_logger.update(key, synced, local_changes)

	-- refresh state
	local ok, cloud_state = true, prev.input
	if not opts.ignore_cloud then
		ok, cloud_state = ctx_log.pcall(api.get :: any, opts.session, prev)
		if not ok then return prev :: any end
	end

	local receiving_changes = api.diff(synced, cloud_state)
	local sending_changes = tbl.intersection(api.diff(cloud_state, input), local_changes)

	sync_logger.print_external_changes(synced, receiving_changes)
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

	return prev :: any
end
local function await_try_reconcile<Lock>(res: any, resource: resource<Lock>, ctx: sync_ctx, snapshot: any?)
	local ok, lock = ctx_log.pcall(await_reconcile, res, resource, ctx, snapshot)
	if ok then resource.lock = lock end
end

local function await_try_reconcile_thumbnails(session: base.session, resources: state.resources)
	local kept = {}
	for _, resource in resources.thumbnails do
		local file = resource.lock and resource.lock.input.image_file
		if file then kept[file.hash] = true end
	end

	for hash, lock in resources.lock.thumbnails do
		if kept[hash] then continue end

		local ok = ctx_log.pcall(thumbnail.delete, session, lock)
		if not ok then continue end

		resources.lock.thumbnails[hash] = nil
		ctx_log.str(`deleted thumbnail {lock.thumbnail_id}`)
	end

	if #resources.thumbnails > 0 then
		local ids = {}
		for _, resource in resources.thumbnails do
			if resource.lock then table.insert(ids, resource.lock.thumbnail_id) end
		end
		local ok = ctx_log.pcall(thumbnail.reorder, session, resources.lock.universe_id, ids)
		if not ok then ctx_log.warn 'couldnt reorder thumbnails' end
	end
end

local function await_reconcile_all(resources: state.resources, opts: sync_opts)
	local snapshot = opts.snapshot or resources.lock
	local ctx: sync_ctx = table.clone(opts :: any)
	ctx.universe_id = resources.lock.universe_id

	if resources.universe then await_try_reconcile(universe, resources.universe, ctx, snapshot.universe) end
	if resources.icon then await_try_reconcile(icon, resources.icon, ctx, snapshot.icon) end
	if resources.manifest.thumbnails then await_try_reconcile_thumbnails(ctx.session, resources) end

	for _, resource in resources.thumbnails do
		await_try_reconcile(thumbnail, resource, ctx)
	end
	for _, resource in resources.products do
		await_try_reconcile(product, resource, ctx, snapshot.products[resource.key])
	end
	for _, resource in resources.places do
		await_try_reconcile(place, resource, ctx, snapshot.places[resource.key])
	end
	for _, resource in resources.passes do
		await_try_reconcile(pass, resource, ctx, snapshot.passes[resource.key])
	end
end

-- module
return table.freeze {
	await_reconcile = await_reconcile,
	await_reconcile_all = await_reconcile_all,
}
