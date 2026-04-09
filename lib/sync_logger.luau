local ctx_log = require '@utils/ctx_log'
local tbl = require '@utils/tbl'

local c = ctx_log.colors
local val_str = ctx_log.val_str

local summary = { creates = 0, updates = 0, noops = 0, errors = 0, conflicts = 0, importeds = 0 }
type set<T = any> = { [string]: T }

-- helpers
local function short_hash(h: string): string
	return h:sub(1, 8)
end
local function fmt_val(value: any): string
	return if type(value) ~= 'table'
		then val_str(value)
		elseif value.hash then `(hash: {short_hash(value.hash)})`
		elseif value.assetid then `(id: {value.assetid})`
		else '(file)'
end

local function print_diff(prev: set, diffs: set, conflicts: set?)
	for key, new in diffs do
		local old = prev[key]
		if old then ctx_log.str(`{c.dim}{c.red}- {key}: {fmt_val(old)}`) end
		if new then
			ctx_log.str(
				if conflicts and conflicts[key] ~= nil
					then `{c.yellow}∙ {key}: {fmt_val(new)} {c.dim}(conflict)`
					else `{c.green}+ {key}: {fmt_val(new)}`
			)
		end
	end
end

-- operation body
local function print_local_changes(prev: set, diffs: set, conflicts: set?)
	if next(diffs) == nil then return ctx_log.str(`{c.dim}no local changes\n`) end
	ctx_log.str(`{c.dim}local changes:`)

	print_diff(prev, diffs, conflicts)
	ctx_log.str ''
end
local function print_external_changes(prev: set, diffs: set, conflicts: set?)
	if next(diffs) == nil then return ctx_log.str(`{c.dim}no external changes\n`) end
	ctx_log.str(`{c.dim}external changes:`)

	print_diff(prev, diffs, conflicts)
	ctx_log.str ''
end
local function print_pushed_changes(pushed: set)
	if next(pushed) == nil then return ctx_log.str(`{c.dim}no changes to push`) end
	ctx_log.str(`{c.dim}pushed changes:`)

	print_diff({}, pushed)
end

-- operations
local function log_noop(key)
	ctx_log.str(`{c.dim}= Skipping: {c.bold}{key}`)
	summary.noops += 1
end
local function log_imported(key: string, product_id: number)
	ctx_log.str(`{c.purple}↓ Imported: {c.bold}{key}{c.reset} {c.dim}(id: {product_id})`)
	summary.importeds += 1
end
local function log_creation(key)
	ctx_log.push_ctx(`{c.green}+ Creating: {c.bold}{key}`)
end
local function log_update(key, prev, diffs)
	ctx_log.push_ctx(`{c.blue}~ Updating: {c.bold}{key}`)
	print_local_changes(prev, diffs)
end

local function log_creation_result(success: boolean)
	ctx_log.pop_ctx(if not success then `{c.red}Failed to publish` else `{c.green}Created`)
	if success then
		summary.creates += 1
	else
		summary.errors += 1
	end
end
local function log_update_result(success: boolean, conflicts: set)
	local conflicts_amount = tbl.count(conflicts)
	ctx_log.pop_ctx(
		if not success
			then `{c.red}Failed to push changes`
			elseif conflicts_amount > 0 then `{c.green}Pushed {c.dim}(aborted {conflicts_amount} conflicts)`
			else `{c.green}Successfully pushed`
	)
	if success then
		summary.updates += 1
		if conflicts_amount > 0 then
			summary.conflicts += 1
		end
	else
		summary.errors += 1
	end
end

-- module level
local function print_header()
	ctx_log.push_ctx(`{c.bold}Syncing products:`)
end
local function print_summary()
	local parts = {}
	if summary.noops > 0 then table.insert(parts, `{c.dim}{summary.noops} noop(s)`) end
	if summary.importeds > 0 then table.insert(parts, `{c.purple}{summary.importeds} imported`) end
	if summary.updates > 0 then table.insert(parts, `{c.blue}{summary.updates} update(s)`) end
	if summary.creates > 0 then table.insert(parts, `{c.green}{summary.creates} create(s)`) end
	if summary.conflicts > 0 then table.insert(parts, `{c.yellow}{summary.conflicts} conflict(s)`) end
	if summary.errors > 0 then table.insert(parts, `{c.red}{summary.errors} error(s)`) end

	local overall = if summary.errors > 0 then `{c.red}Finished with errors` else `{c.green}Succeeded`
	ctx_log.pop_ctx(`{overall}{c.reset}: {table.concat(parts, `{c.reset}, `)}`)
end

-- module
return table.freeze {
	print_header = print_header,
	print_summary = print_summary,

	-- ctx
	update = log_update,
	creation = log_creation,
	noop = log_noop,
	imported = log_imported,
	update_result = log_update_result,
	creation_result = log_creation_result,

	-- diffs
	print_local_changes = print_local_changes,
	print_external_changes = print_external_changes,
	print_pushed_changes = print_pushed_changes,
}
