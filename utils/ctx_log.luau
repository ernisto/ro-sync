-- ANSI escape codes
local COLORS = {
	reset = '\27[0m',
	bold = '\27[1m',
	dim = '\27[2m',
	red = '\27[31m',
	green = '\27[32m',
	yellow = '\27[33m',
	blue = '\27[34m',
}

-- helpers
local function val_str(v: any): string
	return if v == nil then `{COLORS.dim}~{COLORS.reset}` else tostring(v)
end
local function ordered_keys(t: { [string]: any }): { string }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end
local function split_backtrace(tb: string): { string }
	local lines = {}
	for line in tb:gmatch '[^\n]+' do
		local trimmed = line:match '^%s*(.-)%s*$'
		if trimmed and trimmed ~= '' and trimmed ~= 'stack traceback:' then table.insert(lines, trimmed) end
	end
	return lines
end

-- vars
local thread_ctx: { [thread]: ctx } = setmetatable({} :: any, { __mode = 'k' })
local prev_ctx = { thread = coroutine.running(), depth = 0 }
type ctx = { depth: number }

-- functions
local function ensure_ctx(): ctx
	local thread = coroutine.running()
	if prev_ctx.thread == thread then return prev_ctx end

	local ctx = thread_ctx[thread] or { thread = thread, depth = prev_ctx.depth }
	prev_ctx = ctx

	thread_ctx[thread] = ctx
	return ctx
end

local function current_prefix(): string
	local ctx = ensure_ctx()
	return '    ' .. string.rep('│   ', ctx.depth)
end
local function str(msg: string)
	local prefix = current_prefix()
	print(prefix .. msg:gsub('\n', '\n' .. prefix))
end

local function push_ctx(header: string)
	local ctx = ensure_ctx()

	str(header)
	str '╷'
	ctx.depth += 1
end
local function pop_ctx(footer: string)
	local ctx = ensure_ctx()
	str ''
	ctx.depth -= 1
	str('╰── ' .. footer)
end

-- shorthands
local function warn(msg: string)
	str(`{COLORS.yellow}⚠  {msg}{COLORS.reset}`)
end

local function push_backtrace(tb: string)
	for _, line in split_backtrace(tb) do
		str(line)
	end
end

local function push_err(msg: string, backtrace: string?)
	str(`{COLORS.red}✗  {COLORS.bold}{msg}{COLORS.reset}`)
	if backtrace then push_backtrace(backtrace) end
end

local function try_result(fun, ...)
	return xpcall(fun, function(err)
		push_backtrace(debug.traceback(tostring(err), 2))
	end, ...)
end

local function push_http(method: string, url: string, ok: boolean, code: number?, err_msg: string?)
	local status
	if ok then
		status = `{COLORS.green}OK {code or 200}{COLORS.reset}`
	else
		local code_str = if code then tostring(code) else '???'
		local detail = if err_msg then `: {err_msg}` else ''
		status = `{COLORS.red}FAIL {code_str}{detail}{COLORS.reset}`
	end
	str(`{COLORS.dim}({method}) {url}{COLORS.reset} {status}`)
end

-- module
return table.freeze {
	push_ctx = push_ctx,
	pop_ctx = pop_ctx,
	str = str,
	warn = warn,
	error = push_err,
	backtrace = push_backtrace,
	http = push_http,
	try_result = try_result,

	colors = COLORS,
	val_str = val_str,
	sorted_keys = ordered_keys,
}
