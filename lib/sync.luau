local cloud = require '@pkg/ro_cloud'
local tbl = require '@utils/tbl'

local fs = require '@lune/fs'
local serde = require '@lune/serde'

local state = require './state'

-- types
export type product_lock = state.product_lock
export type product_patch = product_lock & { icon_bytes: buffer? }

-- we do flat, so we can easily diff inputs
type flat_product = cloud.product_identity & {
	name: string,
	icon_id: number,
	price: number?,
	description: string?,
	is_for_sale: boolean?,
	regional_pricing: boolean?,
	store_page_enabled: boolean?,
}

export type cloud_api = {
	create: (cloud.universe_identity, state.product_input & { icon_bytes: buffer? }) -> flat_product,
	update: (cloud.product_identity, state.product_input & { icon_bytes: buffer? }) -> (),
	get: (cloud.product_identity) -> flat_product,
}

export type sync_opts = {
	universe_id: number,
	force_fresh_state: boolean?,
}

-- helpers
local function maybe_read(path: string): buffer?
	return if fs.isFile(path) then buffer.fromstring(fs.readFile(path)) else warn(`file '{path}' not exist`)
end

-- functions
local function sync_product(
	key: string,
	input: state.product_input,
	prev: state.product_lock?,
	api: cloud_api,
	opts: sync_opts
): product_lock
	local icon_content = input.icon and maybe_read(input.icon)
	local icon_hash = icon_content and serde.hash('sha256', icon_content)

	if not prev then
		local product = api.create(opts, tbl.applied(input, { icon_bytes = icon_content }))
		return {
			universe_id = product.universe_id,
			product_id = product.product_id,
			icon_id = product.icon_id,
			icon_hash = icon_hash,
			input = input,
		}
	end

	-- get local changes
	local prev_input = state.pick_fields(prev.input)
	local new_input = state.pick_fields(input)

	local sending = tbl.changes(prev_input, new_input)
	local is_sending_icon = icon_hash ~= nil and prev.icon_hash ~= icon_hash

	-- skip unecessary
	if input.conflicts then tbl.subtract(sending, input.conflicts) end

	local is_same_input = next(sending) == nil and not is_sending_icon
	if is_same_input and not opts.force_fresh_state then return prev end

	-- pull
	local current = api.get(prev)
	local cloud_input = state.pick_fields(current)

	local receiving = tbl.changes(prev_input, cloud_input)
	local is_receiving_icon = prev.icon_id and prev.icon_id ~= state.UNAVAILABLE_ID and prev.icon_id ~= current.icon_id

	-- remove changes already received
	sending = tbl.changes(receiving, sending)

	-- find conflicts
	local conflicts = tbl.intersection(receiving, sending)
	if input.conflicts then tbl.apply(conflicts, input.conflicts) end

	if is_receiving_icon and is_sending_icon then conflicts.icon = is_receiving_icon end
	input.conflicts = if next(conflicts) then conflicts else nil

	-- resolve
	local is_free_sending_icon = is_sending_icon and not conflicts.icon
	local free_sending = tbl.subtract(sending, conflicts)

	local free_receiving = tbl.subtraction(receiving, conflicts)
	local relevant_receiving = tbl.intersection(free_receiving, input)
	tbl.apply(input, relevant_receiving)

	-- push
	local patch = tbl.applied(sending, { icon_bytes = if is_free_sending_icon then current.icon_id else nil })
	if next(patch) then
		local success = xpcall(api.update, warn, prev, patch)
		if success then tbl.apply(prev.input, free_sending) end
	end
	tbl.apply(prev.input, receiving)

	-- save
	local latest_icon_id = if is_free_sending_icon then state.UNAVAILABLE_ID else current.icon_id
	return tbl.apply(prev, { icon_hash = icon_hash, icon_id = latest_icon_id })
end

-- module
return table.freeze { sync_product = sync_product }
