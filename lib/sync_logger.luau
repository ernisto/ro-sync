local ctx_log = require '@utils/ctx_log'

local c = ctx_log.colors
local val_str = ctx_log.val_str

-- types
export type field_change = { old: any, new: any }
export type push_state = { lock: any, cloud: any?, local_val: any?, conflict: boolean? }
export type summary = { creates: number, updates: number, noops: number, errors: number, conflicts: number }

type diff = { [string]: field_change }
type set<T = any> = { [string]: T }

-- helpers
local function short_hash(h: string): string
	return h:sub(1, 8)
end
local function diff_by_local(prev: set, sending: set, old_hash: string?, new_hash: string?): diff
	local out = {}
	for k, v in sending do
		out[k] = { old = prev[k], new = v }
	end
	if new_hash and old_hash ~= new_hash then
		out.icon = { new = `(hash: {short_hash(new_hash)})`, old = old_hash and `(hash: {short_hash(old_hash)})` }
	end
	return out
end
local function diff_by_cloud(prev: set, receiving: set, old_id: number?, new_id: number?): diff
	local out = {}
	for k, v in receiving do
		out[k] = { old = prev[k], new = v }
	end
	-- stylua: ignore
	if new_id and old_id ~= new_id then
		out.icon = { new = `(id: {new_id})`, old = old_id and `(id: {old_id})` }
	end
	return out
end
local function print_diff(diffs: diff, conflicts: set?)
	for key, field in diffs do
		ctx_log.str(`{c.dim}{c.red}- {key}: {val_str(field.old)}{c.reset}`)
		ctx_log.str(
			if conflicts and conflicts[key] ~= nil
				then `{c.yellow}∙ {key}: {val_str(field.new)} {c.dim}(conflict){c.reset}`
				else `{c.green}+ {key}: {val_str(field.new)}{c.reset}`
		)
	end
end

-- helpers
local function print_local_changes(diffs: diff)
	if next(diffs) == nil then return ctx_log.str(`{c.dim}no local changes{c.reset}\n`) end

	ctx_log.str(`{c.dim}local changes:{c.reset}`)
	print_diff(diffs)
	ctx_log.str ''
end
local function print_external_changes(diffs: diff, conflicts: set?)
	if next(diffs) == nil then return ctx_log.str(`{c.dim}no external changes{c.reset}\n`) end

	ctx_log.str(`{c.dim}external changes:{c.reset}`)
	print_diff(diffs, conflicts)
	ctx_log.str ''
end
local function print_pushed_changes(pushed: set)
	if next(pushed) == nil then return ctx_log.str(`{c.dim}no changes to push{c.reset}`) end

	ctx_log.str(`{c.dim}pushed changes:{c.reset}`)
	print_diff(diff_by_local(pushed, pushed))
end

-- operations
local function print_noop(key)
	ctx_log.str(`{c.dim}= Skipping: {c.bold}{key}{c.reset}`)
end
local function push_create_ctx(key)
	ctx_log.push_ctx(`{c.green}+ Creating: {c.bold}{key}{c.reset}`)
end
local function push_update_ctx(key)
	ctx_log.push_ctx(`{c.blue}~ Updating: {c.bold}{key}{c.reset}`)
end

local function pop_create(success: boolean)
	ctx_log.pop_ctx(if not success then `{c.red}Failed to publish{c.reset}` else `{c.green}Created{c.reset}`)
end
local function pop_update(success: boolean, conflict_count: number)
	ctx_log.pop_ctx(
		if not success
			then `{c.red}Failed to push changes{c.reset}`
			elseif conflict_count > 0 then `{c.green}Pushed {c.dim}(aborted {conflict_count} conflict(s)){c.reset}`
			else `{c.green}Successfully pushed{c.reset}`
	)
end

-- module level
local function print_header()
	ctx_log.push_ctx(`{c.bold}Syncing products:{c.reset}`)
end
local function print_summary(summary: summary)
	local parts = {
		`{c.dim}{summary.noops} noop(s){c.reset}`,
		`{c.yellow}{summary.conflicts} conflict(s){c.reset}`,
		`{c.green}{summary.creates} create(s){c.reset}`,
		`{c.blue}{summary.updates} update(s){c.reset}`,
		`{c.red}{summary.errors} error(s){c.reset}`,
	}
	local overall = if summary.errors > 0 then `{c.red}Finished with errors{c.reset}` else `{c.green}Succeeded{c.reset}`
	ctx_log.pop_ctx(`{overall}: {table.concat(parts, ', ')}`)
end

-- module
return table.freeze {
	print_header = print_header,
	print_summary = print_summary,

	-- ctx
	push_update = push_update_ctx,
	push_create = push_create_ctx,
	print_noop = print_noop,
	pop_update = pop_update,
	pop_create = pop_create,

	-- diffs
	print_local_changes = print_local_changes,
	print_external_changes = print_external_changes,
	print_pushed_changes = print_pushed_changes,

	diff_by_local = diff_by_local,
	diff_by_cloud = diff_by_cloud,
}
