local ctx_log = require '@utils/ctx_log'

local c = ctx_log.c
local val_str = ctx_log.val_str
local sorted_keys = ctx_log.sorted_keys

-- types
export type field_change = { old: any, new: any }
export type push_state = { lock: any, cloud: any?, local_val: any?, conflict: boolean? }

-- helpers
local function make_diffs(from: { [string]: any }, changes: { [string]: any }): { [string]: field_change }
	local out = {}
	for k, new_v in changes do
		out[k] = { old = from[k], new = new_v }
	end
	return out
end

type sync_data = {
	prev_input: { [string]: any },
	receiving: { [string]: any },
	original_sending: { [string]: any },
	conflicts: { [string]: any },
	is_sending_icon: boolean,
	is_receiving_icon: any,
	icon_hash: string?,
}

local function make_push_state(data: sync_data): { [string]: push_state }
	local pushed: { [string]: push_state } = {}
	for k, cloud_v in data.receiving do
		pushed[k] = { lock = data.prev_input[k], cloud = cloud_v }
	end
	for k, local_v in data.original_sending do
		local p: push_state = pushed[k] or { lock = data.prev_input[k] }
		p.local_val = local_v
		p.conflict = data.conflicts[k] ~= nil
		pushed[k] = p
	end
	if data.is_sending_icon or data.is_receiving_icon then
		pushed['icon'] = {
			lock = data.icon_hash,
			cloud = if data.is_receiving_icon then '(changed)' else nil,
			local_val = if data.is_sending_icon then '(changed)' else nil,
			conflict = not not data.conflicts.icon,
		}
	end
	return pushed
end

local function simple_diff_lines(keys: { string }, diffs: { [string]: field_change })
	local prefix = ctx_log.pc()
	for _, k in keys do
		local d = diffs[k]
		ctx_log.push(`{prefix}{c.dim}{c.red}-   {k}: {val_str(d.old)}{c.reset}`)
		ctx_log.push(`{prefix}{c.green}+   {k}: {val_str(d.new)}{c.reset}`)
	end
end

-- sync-specific log functions

local function local_changes(diffs: { [string]: field_change }, with_icon: boolean)
	local prefix = ctx_log.pc()
	ctx_log.push(`{prefix}{c.dim}local changes:{c.reset}`)
	if next(diffs) == nil and not with_icon then
		ctx_log.push(`{prefix}{c.dim}(no field changes){c.reset}`)
	else
		simple_diff_lines(sorted_keys(diffs), diffs)
		if with_icon then ctx_log.push(`{prefix}{c.dim}~   icon: (changed){c.reset}`) end
	end
	ctx_log.push(prefix)
end

local function cloud_changes(diffs: { [string]: field_change }, with_icon: boolean, conflicts: { [string]: any }?)
	local prefix = ctx_log.pc()
	ctx_log.push(`{prefix}{c.dim}external changes:{c.reset}`)
	if next(diffs) == nil and not with_icon then
		ctx_log.push(`{prefix}{c.dim}(no external changes){c.reset}`)
		ctx_log.push(prefix)
		return
	end
	for _, k in sorted_keys(diffs) do
		local d = diffs[k]
		if conflicts and conflicts[k] ~= nil then
			ctx_log.push(`{prefix}{c.dim}{c.red}-   {k}: {val_str(d.old)}{c.reset}`)
			ctx_log.push(`{prefix}{c.yellow}+   {k}: {val_str(d.new)} {c.dim}(conflict){c.reset}`)
		else
			ctx_log.push(`{prefix}{c.dim}{c.red}-   {k}: {val_str(d.old)}{c.reset}`)
			ctx_log.push(`{prefix}{c.green}+   {k}: {val_str(d.new)}{c.reset}`)
		end
	end
	if with_icon then
		if conflicts and conflicts.icon ~= nil then
			ctx_log.push(`{prefix}{c.yellow}~   icon: (changed) {c.dim}(conflict){c.reset}`)
		else
			ctx_log.push(`{prefix}{c.dim}~   icon: (changed){c.reset}`)
		end
	end
	ctx_log.push(prefix)
end

local function pushed_changes(data: sync_data)
	local fields: { [string]: push_state } = make_push_state(data)
	local prefix = ctx_log.pc()

	ctx_log.push(`{prefix}{c.dim}pushed changes:{c.reset}`)
	local keys = {}
	for k, f in fields do
		if f.local_val ~= nil then table.insert(keys, k) end
	end
	table.sort(keys)
	if #keys == 0 then
		ctx_log.push(`{prefix}{c.dim}(no local changes to push){c.reset}`)
		ctx_log.push(prefix)
		return
	end
	for _, k in keys do
		local f = fields[k]
		if f.conflict then
			ctx_log.push(`{prefix}{c.yellow}!   {k}: {val_str(f.local_val)} {c.dim}(conflict){c.reset}`)
		else
			ctx_log.push(`{prefix}{c.green}+   {k}: {val_str(f.local_val)}{c.reset}`)
		end
	end
	ctx_log.push(prefix)
end

-- module-level print functions
local outer = ctx_log.build_prefix(0)

local function print_header()
	print(`{c.bold}Syncing products:{c.reset}`)
	print(outer .. '╷')
end

local function print_summary(creates: number, updates: number, noops: number, errors: number, conflicts: number)
	local parts = {
		`{c.dim}{noops} noop(s){c.reset}`,
		`{c.yellow}{conflicts} conflict(s){c.reset}`,
		`{c.green}{creates} create(s){c.reset}`,
		`{c.cyan}{updates} update(s){c.reset}`,
		`{c.red}{errors} error(s){c.reset}`,
	}
	local overall = if errors > 0 then `{c.red}Finished with errors{c.reset}` else `{c.green}Succeeded{c.reset}`
	print(outer .. `╰── {overall}: {table.concat(parts, ', ')}`)
end

return table.freeze {
	local_changes = local_changes,
	cloud_changes = cloud_changes,
	pushed_changes = pushed_changes,
	make_diffs = make_diffs,
	make_push_state = make_push_state,
	print_header = print_header,
	print_summary = print_summary,
}
