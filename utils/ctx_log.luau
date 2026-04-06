-- ANSI escape codes
local c = {
	reset = '\27[0m',
	bold = '\27[1m',
	dim = '\27[2m',
	red = '\27[31m',
	green = '\27[32m',
	yellow = '\27[33m',
	cyan = '\27[36m',
}

-- box geometry
local INDENT = '   '

local function build_prefix(depth: number): string
	local s = INDENT
	for _ = 1, depth do
		s ..= '│' .. INDENT
	end
	return s
end

-- value display helper
local function val_str(v: any): string
	return if v == nil then `{c.dim}~{c.reset}` else tostring(v)
end

local function sorted_keys(t: { [string]: any }): { string }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

-- per-coroutine context
type ctx = {
	key: string,
	p: string,
	pc: string,
	box_open: string,
	box_close: string,
	buf: { string },
	action_str: string,
	flushed: boolean,
	saved_conflicts: number,
}

local store: { [thread]: ctx } = setmetatable({} :: any, { __mode = 'k' })

local function ctx_get(): ctx?
	return store[coroutine.running() :: thread]
end

local function split_traceback(tb: string, pc: string): { string }
	local lines = {}
	for line in tb:gmatch '[^\n]+' do
		local trimmed = line:match '^%s*(.-)%s*$'
		if trimmed ~= '' and trimmed ~= 'stack traceback:' then table.insert(lines, `{pc}{c.dim}{trimmed}{c.reset}`) end
	end
	return lines
end

-- initialize context for the current coroutine
local function init(key: string, in_depth: number?)
	local depth = in_depth or 1
	local p = build_prefix(depth)
	local pc = build_prefix(depth + 1)
	store[coroutine.running() :: thread] = {
		key = key,
		p = p,
		pc = pc,
		box_open = p .. '╷',
		box_close = p .. '╰── ',
		buf = {},
		action_str = '',
		flushed = false,
		saved_conflicts = 0,
	}
end

-- append a raw line to the current context's buffer
local function push(line: string)
	local ctx = ctx_get()
	if ctx then table.insert(ctx.buf, line) end
end

-- returns the content prefix for the current context
local function pc(): string
	local ctx = ctx_get()
	return if ctx then ctx.pc else build_prefix(2)
end

-- generic log functions — all no-ops when no context is set

local function start(action: string)
	local ctx = ctx_get()
	if not ctx then return end

	ctx.action_str = action
	local sym, col, verb
	if action == 'create' then
		sym, col, verb = '+', c.green, 'Creating'
	elseif action == 'update' then
		sym, col, verb = '~', c.yellow, 'Updating'
	else
		sym, col, verb = '=', c.dim, 'Skipping'
	end
	table.insert(ctx.buf, ctx.p .. `{col}{sym} {verb}: {c.bold}{ctx.key}{c.reset}`)
	if action ~= 'noop' then table.insert(ctx.buf, ctx.box_open) end
end

local function print_line(msg: string)
	local ctx = ctx_get()
	if ctx then table.insert(ctx.buf, ctx.pc .. msg) end
end

local function log(msg: string)
	local ctx = ctx_get()
	if ctx then table.insert(ctx.buf, `{ctx.pc}{c.dim}{msg}{c.reset}`) end
end

local function warn(msg: string)
	local ctx = ctx_get()
	if ctx then table.insert(ctx.buf, `{ctx.pc}{c.yellow}⚠  {msg}{c.reset}`) end
end

local function error_fn(msg: string, tb: string?)
	local ctx = ctx_get()
	if not ctx then return end

	table.insert(ctx.buf, `{ctx.pc}{c.red}✗  {c.bold}{msg}{c.reset}`)
	if tb then
		for _, line in split_traceback(tb, ctx.pc) do
			table.insert(ctx.buf, line)
		end
	end
end

local function traceback(tb: string)
	local ctx = ctx_get()
	if not ctx then return end

	for _, line in split_traceback(tb, ctx.pc) do
		table.insert(ctx.buf, line)
	end
end

local function http(method: string, path: string, ok: boolean, code: number?, err_msg: string?)
	local ctx = ctx_get()
	if not ctx then return end

	local status
	if ok then
		status = `{c.green}OK {code or 200}{c.reset}`
	else
		local code_str = if code then tostring(code) else '???'
		local detail = if err_msg then `: {err_msg}` else ''
		status = `{c.red}FAIL {code_str}{detail}{c.reset}`
	end
	table.insert(ctx.buf, `{ctx.pc}{c.dim}({method}) {path}{c.reset} {status}`)
end

local function done(success: boolean, conflict_count: number?)
	local ctx = ctx_get()
	if not ctx or ctx.flushed then return end

	ctx.flushed = true
	conflict_count = conflict_count or 0
	ctx.saved_conflicts = conflict_count or 0

	if ctx.action_str == '' then
		table.insert(ctx.buf, ctx.p .. `{c.red}✗ Error: {c.bold}{ctx.key}{c.reset}`)
		table.insert(ctx.buf, ctx.box_open)
	end
	if ctx.action_str ~= 'noop' then
		local result = if not success
			then `{c.red}Failed to push changes{c.reset}`
			elseif ctx.action_str == 'create' then `{c.green}Created{c.reset}`
			elseif conflict_count > 0 then `{c.green}Successfully pushed {c.dim}({conflict_count} conflict(s)){c.reset}`
			else `{c.green}Successfully pushed{c.reset}`

		table.insert(ctx.buf, ctx.box_close .. result)
	end
	table.insert(ctx.buf, ctx.p)
	print(table.concat(ctx.buf, '\n'))
end

local function get_action(): string
	local ctx = ctx_get()
	return if ctx then ctx.action_str else ''
end

local function get_conflicts(): number
	local ctx = ctx_get()
	return if ctx then ctx.saved_conflicts else 0
end

return table.freeze {
	-- context lifecycle
	init = init,
	-- generic log
	push = push,
	pc = pc,
	start = start,
	print = print_line,
	log = log,
	warn = warn,
	error = error_fn,
	traceback = traceback,
	http = http,
	done = done,
	get_action = get_action,
	get_conflicts = get_conflicts,
	-- formatting exports for sync_logger
	c = c,
	val_str = val_str,
	sorted_keys = sorted_keys,
	build_prefix = build_prefix,
}
