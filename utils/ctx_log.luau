local stdio = require '@lune/stdio'

-- ANSI escape codes
local c = {
	reset = '\27[0m',
	bold = '\27[1m',
	unbold = '\027[22m',
	dim = '\27[2m',
	red = '\27[31m',
	green = '\27[32m',
	yellow = '\27[33m',
	blue = '\27[34m',
	purple = '\27[35m',
}

-- helpers
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
local prev_ctx = { thread = coroutine.running(), depth = 0, pending_gap = false }
type ctx = { depth: number, pending_gap: boolean }

-- functions
local function ensure_ctx(): ctx
	local thread = coroutine.running()
	if prev_ctx.thread == thread then return prev_ctx end

	local ctx = thread_ctx[thread] or { thread = thread, depth = prev_ctx.depth, pending_gap = false }
	prev_ctx = ctx

	thread_ctx[thread] = ctx
	return ctx
end

local function current_prefix(): string
	local ctx = ensure_ctx()
	return '    ' .. string.rep('│   ', ctx.depth)
end
local function str(msg: string)
	local ctx = ensure_ctx()
	local prefix = current_prefix()
	if ctx.pending_gap then
		ctx.pending_gap = false
		print(prefix)
	end
	print(prefix .. msg:gsub('\n', `{c.reset}\n{prefix}`) .. c.reset)
end

local function gap()
	ensure_ctx().pending_gap = true
end

local function push_ctx(header: string)
	local ctx = ensure_ctx()

	str(header)
	str '╷'
	ctx.depth += 1
end
local function pop_ctx(footer: string)
	local ctx = ensure_ctx()
	ctx.pending_gap = false
	str ''
	ctx.depth -= 1
	str(`╰── {footer}`)
end

-- shorthands
local function warn(msg: string)
	str(`{c.yellow}⚠ {msg}{c.reset}`)
end

local function push_backtrace(tb: string)
	for _, line in split_backtrace(tb) do
		str(line)
	end
end

local function push_err(msg: string, backtrace: string?)
	str(`{c.red}✗  {c.bold}{msg}`)
	if backtrace then push_backtrace(backtrace) end
end

local function prompt(kind: any, raw_message: any, default_or_options: any): any
	-- lune prepends a 2-char marker to the message and each option, so drop 2 chars to keep the tree aligned
	local prefix = string.sub(current_prefix(), 3)

	local message = if type(raw_message) == 'string' then prefix .. raw_message else raw_message
	local options = default_or_options
	if type(default_or_options) == 'table' then
		options = {}
		for i, option in default_or_options do
			options[i] = prefix .. option
		end
	end

	local result = stdio.prompt(kind, message, options)

	-- dialoguer echoes a summary line reusing our prefixed strings; erase it so the caller can log a clean answer
	if type(raw_message) == 'string' then stdio.write '\27[1A\r\27[2K' end

	return result
end

local function try_result(fun, ...)
	return xpcall(fun, function(err)
		push_backtrace(debug.traceback(tostring(err), 2))
	end, ...)
end

-- module
return table.freeze {
	push_ctx = push_ctx,
	pop_ctx = pop_ctx,
	str = str,
	gap = gap,
	warn = warn,
	error = push_err,
	backtrace = push_backtrace,
	pcall = try_result,
	prompt = prompt :: (() -> string) & ((kind: 'text', message: string?, default: string?) -> string) & ((kind: 'confirm', message: string, default: boolean?) -> boolean) & ((kind: 'select', message: string?, options: { string }) -> number?) & ((kind: 'multiselect', message: string?, options: { string }) -> { number }?),

	colors = c,
}
