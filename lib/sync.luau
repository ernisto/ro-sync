local ctx_log = require '@utils/ctx_log'
local tbl = require '@utils/tbl'

local asset = require './resources/asset'
local base = require './resources/base'
local config = require './resources/config'
local icon = require './resources/icon'
local pass = require './resources/pass'
local place = require './resources/place'
local place_configuration = require './resources/place_configuration'
local product = require './resources/product'
local thumbnail = require './resources/thumbnail'
local universe = require './resources/universe'
local universe_configuration = require './resources/universe_configuration'

local state = require './state'
local sync_logger = require './sync_logger'

-- defs
export type sync_opts = {
	session: base.session,
	snapshot: state.lock?, -- lock before any cloud import; defaults to the current lock
	ignore_cloud: boolean?,
	resolve_to: side?, -- side that wins conflicts; none records them
	mode: sync_mode,
}

export type side = 'cloud' | 'local'

-- push: send local changes
-- receive: only take cloud changes, local ones stay pending
-- dry: report only, change nothing
export type sync_mode = 'push' | 'receive' | 'dry'

export type sync_ctx = {
	session: base.session,
	universe_id: number,
	ignore_cloud: boolean?,
	resolve_to: side?, -- side that wins conflicts; none records them
	mode: sync_mode,
}

type resource<Lock = any> = {
	key: string,
	lock: resource_lock?,
	input: { [string]: any, conflicts: { [string]: any } },
}

type resource_lock = { universe_id: number, input: { [string]: any }, [string]: any }
type resource_api = {
	diff: ({ [string]: any }, { [string]: any }) -> { [string]: any },
	get: nil | (any, any) -> { [string]: any },
	update: (any, any, { [string]: any }) -> ({ [string]: any }, string?),
	create: ((any, sync_ctx, any, string) -> resource_lock)?,
	validate: (({ [string]: any }) -> ())?,
}

-- functions
local function await_reconcile<Lock>(res: any, resource: resource<Lock>, opts: sync_ctx, snapshot: resource_lock?): Lock
	local api: resource_api = res

	local key, input, prev = resource.key, resource.input, resource.lock
	if api.validate then api.validate(input) end

	-- stubbed crud methods (base.unsupported) count as missing
	local create = if base.supports(api.create) then api.create else nil
	local get = if base.supports(api.get) then api.get else nil

	if not prev and not create then
		-- `path`: identity to baseline from, set by sub-resources (see await_try_reconcile_configuration)
		local path = (resource :: any).path or { universe_id = opts.universe_id }
		prev = tbl.applied(path, { input = get and get(opts.session, path) }) :: any
	end

	local pushing = opts.mode == 'push'

	if not prev and not pushing then
		sync_logger.noop(`{key} (not created, needs push)`)
		return nil :: any
	end
	if not prev then
		sync_logger.creation(key)
		local ok, created_lock = ctx_log.try(create or error 'resource has no create', opts.session, opts, input, key)
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
	if not opts.ignore_cloud and get then
		ok, cloud_state = ctx_log.try(get, opts.session, prev)
		if not ok then
			sync_logger.update_result(false, local_changes, {})
			return prev :: any
		end
	end

	local receiving_changes = api.diff(synced, cloud_state)
	local sending_changes = tbl.intersection(api.diff(cloud_state, input), local_changes)

	sync_logger.print_external_changes(synced, receiving_changes)

	if opts.mode == 'dry' then
		sync_logger.preview_result(sending_changes)
		return prev :: any
	end

	tbl.apply(prev.input, cloud_state)

	-- conflicts
	local conflicts = input.conflicts
	local conflicted_changes = {}

	local matched = tbl.subtraction(cloud_state, sending_changes)
	tbl.subtract(conflicts, matched)

	if opts.resolve_to == 'local' then
		tbl.subtract(conflicts, sending_changes)
	elseif opts.resolve_to == 'cloud' then
		local cloud_wins = tbl.applied(receiving_changes, conflicts)
		tbl.subtract(sending_changes, cloud_wins)
		tbl.subtract(conflicts, cloud_wins)
	else
		conflicted_changes = tbl.intersection(sending_changes, receiving_changes)
		tbl.apply(conflicts, conflicted_changes)
	end

	-- push
	local free_sending = if pushing then tbl.subtraction(sending_changes, conflicts) else {}
	local held = tbl.subtraction(sending_changes, free_sending)
	local expected = tbl.applied(cloud_state, free_sending)

	local confirmed_state, push_err = cloud_state, nil
	if next(free_sending) then
		-- a raising update (logged by try) still has to close this resource's log and count as an error
		local pushed, updated, err = ctx_log.try(api.update, opts.session, prev, free_sending)
		confirmed_state, push_err = if pushed then updated else {}, if pushed then err else 'update raised'
	end

	confirmed_state = tbl.applied(cloud_state, confirmed_state)
	tbl.apply(prev.input, confirmed_state)

	local confirmed_received = tbl.subtract(tbl.subtraction(confirmed_state, conflicted_changes), held)
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
	local ok, lock = ctx_log.try(await_reconcile, res, resource, ctx, snapshot)
	if ok then resource.lock = lock end
end

-- `configuration:` is its own resource (develop api) whose lock nests in the parent's; needs the parent synced first
local function await_try_reconcile_configuration(res: any, parent: any, ctx: sync_ctx, parent_snapshot: any?)
	local input, lock = parent.input.configuration, parent.lock
	if not input or not lock then return end

	local child = {
		key = `{parent.key}.configuration`,
		input = input,
		lock = lock.configuration,
		path = { universe_id = lock.universe_id, place_id = lock.place_id },
	}
	await_try_reconcile(res, child, ctx, parent_snapshot and parent_snapshot.configuration)
	lock.configuration = child.lock
end

local function await_try_reconcile_thumbnails(session: base.session, resources: state.resources)
	local kept = {}
	for _, resource in resources.thumbnails do
		local file = resource.lock and resource.lock.input.image_file
		if file then kept[file.hash] = true end
	end

	for hash, lock in resources.lock.thumbnails do
		if kept[hash] then continue end

		local ok = ctx_log.try(thumbnail.delete, session, lock)
		if not ok then continue end

		resources.lock.thumbnails[hash] = nil
		ctx_log.str(`deleted thumbnail {lock.thumbnail_id}`)
	end

	if #resources.thumbnails > 0 then
		local ids = {}
		for _, resource in resources.thumbnails do
			if resource.lock then table.insert(ids, resource.lock.thumbnail_id) end
		end
		local ok = ctx_log.try(thumbnail.reorder, session, resources.lock.universe_id, ids)
		if not ok then ctx_log.warn 'couldnt reorder thumbnails' end
	end
end

local function await_sync_assets(resources: state.resources, opts: sync_opts)
	local input = resources.manifest.assets
	if not input or opts.mode == 'dry' then return end

	local prev = resources.lock.assets or {}

	if opts.mode == 'push' then
		resources.lock.assets = asset.create(opts.session, resources.manifest.owner, input, prev)
	else
		resources.lock.assets = asset.receive(input, prev)
	end
end

local function await_reconcile_all(resources: state.resources, opts: sync_opts)
	local snapshot = opts.snapshot or resources.lock
	local ctx: sync_ctx = table.clone(opts :: any)
	ctx.universe_id = resources.lock.universe_id

	local joins = {}
	local function spawn(fun: () -> ())
		table.insert(joins, ctx_log.spawn(fun))
	end

	if resources.universe then
		spawn(function()
			await_try_reconcile(universe, resources.universe, ctx, snapshot.universe)
			await_try_reconcile_configuration(universe_configuration, resources.universe, ctx, snapshot.universe)
		end)
	end
	if resources.icon then spawn(function()
		await_try_reconcile(icon, resources.icon, ctx, snapshot.icon)
	end) end

	spawn(function()
		if resources.manifest.thumbnails and ctx.mode == 'push' then
			await_try_reconcile_thumbnails(ctx.session, resources)
		end
		for _, resource in resources.thumbnails do
			await_try_reconcile(thumbnail, resource, ctx)
		end
	end)
	for _, resource in resources.products do
		spawn(function()
			await_try_reconcile(product, resource, ctx, snapshot.products[resource.key])
		end)
	end
	for _, resource in resources.places do
		spawn(function()
			await_try_reconcile(place, resource, ctx, snapshot.places[resource.key])
			await_try_reconcile_configuration(place_configuration, resource, ctx, snapshot.places[resource.key])
		end)
	end
	for _, resource in resources.passes do
		spawn(function()
			await_try_reconcile(pass, resource, ctx, snapshot.passes[resource.key])
		end)
	end
	for _, resource in resources.configs do
		spawn(function()
			await_try_reconcile(config, resource, ctx, snapshot.configs[resource.key])
		end)
	end

	for _, join in joins do
		join()
	end

	await_sync_assets(resources, opts)
end

-- module
return table.freeze {
	await_reconcile = await_reconcile,
	await_reconcile_all = await_reconcile_all,
}
