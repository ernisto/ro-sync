local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local tbl = require '@utils/tbl'

local state = require './state'
local sync_logger = require './sync_logger'
local types = require './types'

-- types
export type sync_opts = { universe_id: number, force_fresh_state: boolean? }
export type cloud_api = {
	create: (cloud.universe_identity, state.product_input) -> types.flat_product,
	update: (cloud.product_identity, state.product_input) -> (),
	get: (cloud.product_identity) -> types.flat_product,
}

-- functions
local function await_create_product(api: cloud_api, product: state.product, opts: sync_opts)
	local key, input = product.key, product.input
	sync_logger.creation(key)

	local success, result = ctx_log.pcall(api.create, opts, input)
	sync_logger.print_pushed_changes(input)
	sync_logger.creation_result(success)

	local saved_icon =
		{ assetid = result.icon and result.icon.assetid, hash = input.icon_file and input.icon_file.hash }
	local saved_input = tbl.applied(input, { icon_file = saved_icon })

	return { universe_id = result.universe_id, product_id = result.product_id, input = saved_input }
end
local function await_reconcile_product(api: cloud_api, product: state.product, opts: sync_opts): state.product_lock
	local key, input, prev = product.key, product.input, product.lock
	if not prev then return await_create_product(api, product, opts) end

	local conflicts = input.conflicts or {}

	local local_changes = state.diff_product(prev.input, input)
	tbl.subtract(local_changes, conflicts)

	if next(local_changes) == nil and not opts.force_fresh_state then
		sync_logger.noop(key)
		return prev
	end

	sync_logger.update(key, prev.input, local_changes)

	-- pull
	local current = api.get(prev)
	local receiving_changes = state.diff_product(prev.input, current)
	local sending_changes = tbl.changes(receiving_changes, local_changes)

	tbl.apply(conflicts, tbl.intersection(receiving_changes, sending_changes))
	sync_logger.print_external_changes(prev.input, receiving_changes, conflicts)

	-- resolve
	local free_sending = tbl.subtraction(sending_changes, conflicts)
	local free_receiving = tbl.subtraction(receiving_changes, conflicts)

	tbl.apply(input, free_receiving)

	-- push
	local successfully_pushed = next(free_sending) == nil or ctx_log.pcall(api.update, prev, free_sending)
	if successfully_pushed then tbl.apply(prev.input, free_sending) end

	tbl.apply(prev.input, receiving_changes)
	sync_logger.print_pushed_changes(free_sending)
	sync_logger.update_result(successfully_pushed, free_sending, conflicts)

	return prev
end

-- module
return table.freeze { await_reconcile_product = await_reconcile_product }
