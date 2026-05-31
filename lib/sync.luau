local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local tbl = require '@utils/tbl'

local state = require './state'
local sync_logger = require './sync_logger'
local types = require './types'

-- types
export type sync_opts = { universe_id: number, force_fresh_state: boolean? }
export type cloud_api = {
	create: (cloud.universe_identity, state.product_input) -> types.product_read,
	update: (cloud.product_identity, state.product_input) -> (),
	get: (cloud.product_identity) -> types.product_read,
}
export type place_read = state.place_data & { universe_id: number, place_id: number }
export type place_api = {
	create: (sync_opts, state.place_input) -> place_read,
	update: (cloud.place_identity, state.place_input) -> (),
	get: (cloud.place_identity) -> state.place_data,
}
export type universe_api = {
	update: (cloud.universe_identity, state.universe_input) -> (),
	get: (cloud.universe_identity) -> state.universe_data,
}

type descriptor = {
	diff: ({ [string]: any }, { [string]: any }) -> { [string]: any },
	get: ((any) -> { [string]: any })?,
	update: (any, { [string]: any }) -> (),
	validate: (({ [string]: any }) -> ())?,
}

-- generic 3-way merge — mutates `input` (manifest side) and `prev.input` (lock side)
local function reconcile(d: descriptor, key: string, input: any, prev: any, opts: sync_opts)
	local conflicts = input.conflicts
	if d.validate then d.validate(input) end

	local local_changes = d.diff(prev.input, input)
	tbl.subtract(local_changes, conflicts)

	if next(local_changes) == nil and not opts.force_fresh_state then
		sync_logger.noop(key)
		return
	end

	sync_logger.update(key, prev.input, local_changes)

	-- pull (skipped for push-only resources where `get` is nil)
	local receiving_changes: { [string]: any } = {}
	if d.get then
		local current = d.get(prev)
		receiving_changes = d.diff(prev.input, current)
	end
	local sending_changes = tbl.changes(receiving_changes, local_changes)

	tbl.apply(conflicts, tbl.intersection(receiving_changes, sending_changes))
	sync_logger.print_external_changes(prev.input, receiving_changes, conflicts)

	-- resolve
	local free_sending = tbl.subtraction(sending_changes, conflicts)
	local free_receiving = tbl.subtraction(receiving_changes, conflicts)

	tbl.apply(input, free_receiving)

	-- push
	local successfully_pushed = next(free_sending) == nil or ctx_log.pcall(d.update, prev, free_sending)
	if successfully_pushed then tbl.apply(prev.input, free_sending) end

	tbl.apply(prev.input, receiving_changes)
	sync_logger.print_pushed_changes(free_sending)
	sync_logger.update_result(successfully_pushed, free_sending, conflicts)
end

-- products (the only creatable resource)
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

	reconcile({
		diff = state.diff_product,
		get = api.get,
		update = api.update,
		validate = function(input)
			if input.icon and not input.icon_file then ctx_log.warn(`couldnt find icon '{input.icon}'`) end
		end,
	}, product.key, product.input, prev, opts)

	return prev
end

-- places (created via assets.create; settings merge + push-only file upload thereafter)
local function await_create_place(api: place_api, place: state.place, opts: sync_opts): state.place_lock
	local key, input = place.key, place.input
	if not input.display_name then error(`place '{key}' needs a display_name to be created`) end
	if not input.asset_file then
		local missing = if input.file then `file '{input.file}' not found` else 'no file set'
		error(`place '{key}' has {missing}; a .rbxl file is required to create a place`)
	end
	sync_logger.creation(key)

	local success, result = ctx_log.pcall(api.create, opts, input)
	sync_logger.print_pushed_changes(tbl.subtraction(input, { file = true, conflicts = true }))
	sync_logger.creation_result(success)

	-- store only the file hash in the lock so an identical file isn't re-uploaded next sync
	tbl.apply(result, { asset_file = { hash = input.asset_file.hash } })

	return { universe_id = result.universe_id, place_id = result.place_id, input = result }
end
local function await_reconcile_place(api: place_api, place: state.place, opts: sync_opts): state.place_lock
	local prev = place.lock
	if not prev then return await_create_place(api, place, opts) end

	reconcile({
		diff = state.diff_place,
		get = api.get,
		update = api.update,
		validate = function(input)
			if input.file and not input.asset_file then ctx_log.warn(`couldnt find place file '{input.file}'`) end
		end,
	}, place.key, place.input, prev, opts)

	return prev
end

-- universe settings (single resource; never created — baseline pulled from cloud on first run)
local function await_reconcile_universe(
	api: universe_api,
	universe: state.universe,
	opts: sync_opts
): state.universe_lock
	local prev = universe.lock or { universe_id = opts.universe_id, input = api.get { universe_id = opts.universe_id } }

	reconcile(
		{ diff = state.diff_universe, get = api.get, update = api.update },
		universe.key,
		universe.input,
		prev,
		opts
	)

	return prev
end

-- module
return table.freeze {
	await_reconcile_product = await_reconcile_product,
	await_reconcile_place = await_reconcile_place,
	await_reconcile_universe = await_reconcile_universe,
}
