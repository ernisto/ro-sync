local process = require '@lune/process'
local stdio = require '@lune/stdio'
local task = require '@lune/task'

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
local prev_ctx: ctx = { thread = coroutine.running(), depth = 0, pending_gap = false, gapped = false }
type ctx = { thread: thread, depth: number, pending_gap: boolean, gapped: boolean, lines: { string }? }

-- functions
local function ensure_ctx(): ctx
	local thread = coroutine.running()
	if prev_ctx.thread == thread then return prev_ctx end

	local ctx = thread_ctx[thread] or { thread = thread, depth = prev_ctx.depth, pending_gap = false, gapped = false }
	prev_ctx = ctx

	thread_ctx[thread] = ctx
	return ctx
end

-- spawned threads buffer their lines until they finish, so concurrent output stays grouped
local function write(ctx: ctx, line: string)
	if ctx.lines then
		table.insert(ctx.lines, line)
	else
		print(line)
	end
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
		write(ctx, prefix)
	end

	ctx.gapped = false
	write(ctx, prefix .. msg:gsub('\n', `{c.reset}\n{prefix}`) .. c.reset)
end

local function gap()
	local ctx = ensure_ctx()
	if ctx.gapped then return end
	ctx.pending_gap = true
end

local function push_ctx(header: string)
	local ctx = ensure_ctx()

	str(header)
	str '╷'
	ctx.gapped = true
	ctx.depth += 1
end
local function pop_ctx(footer: string)
	local ctx = ensure_ctx()
	ctx.pending_gap = false
	ctx.gapped = false
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

local function throw(msg: string)
	local backtrace = debug.traceback():sub(2)
	push_err(msg, backtrace)
	return process.exit(1)
end

local function clear_line()
	local ctx = ensure_ctx()
	if ctx.lines then
		table.remove(ctx.lines)
	else
		stdio.write '\27[1A\r\27[2K'
	end
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
	if type(raw_message) == 'string' then clear_line() end

	return result
end

-- closes scopes the failed call left open, so following logs keep their depth
local function try_result(fun: any, ...): ...any
	local ctx = ensure_ctx()
	local depth = ctx.depth
	local result: any = table.pack(xpcall(fun, function(err)
		push_err(tostring(err), debug.traceback('', 2))
	end, ...))
	if not result[1] then
		while ctx.depth > depth do
			pop_ctx(`{c.red}failed{c.reset}`)
		end
	end
	return table.unpack(result, 1, result.n)
end

-- runs `fun` in a new thread whose logs flush to the caller's output at once when it ends; returns a joiner
local function spawn<A...>(fun: (A...) -> ...any, ...: A...): () -> ()
	local parent = ensure_ctx()
	local done, waiters: { thread } = false, {}

	local thread = coroutine.create(function(...)
		local lines = ensure_ctx().lines :: { string }
		try_result(fun, ...)

		for _, line in lines do
			write(parent, line)
		end
		done = true
		for _, waiter in waiters do
			task.spawn(waiter)
		end
	end)
	thread_ctx[thread] = { thread = thread, depth = parent.depth, pending_gap = false, gapped = false, lines = {} }
	task.spawn(thread, ...)

	return function()
		if done then return end
		table.insert(waiters, coroutine.running())
		coroutine.yield()
	end
end

-- module
return table.freeze {
	push_ctx = push_ctx,
	pop_ctx = pop_ctx,
	str = str,
	gap = gap,
	warn = warn,
	throw = throw,
	print_error = push_err,
	clear_line = clear_line,
	backtrace = push_backtrace,
	spawn = spawn,
	try = (try_result :: any) :: <A..., R...>((A...) -> R..., A...) -> (boolean, R...),
	prompt = prompt :: (() -> string) & ((kind: 'text', message: string?, default: string?) -> string) & ((kind: 'confirm', message: string, default: boolean?) -> boolean) & ((kind: 'select', message: string?, options: { string }) -> number?) & ((kind: 'multiselect', message: string?, options: { string }) -> { number }?),

	colors = c,
}
