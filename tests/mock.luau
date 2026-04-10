-- defs
export type spy = typeof(setmetatable(
	{} :: { calls: { { any } }, call_count: number },
	{} :: { __call: (any, ...any) -> ...any }
))

-- functions
local function fn<Func>(impl: Func?): Func & { call_count: number, calls: { any } }
	assert(not impl or type(impl) == 'function')
	local self = { calls = {}, call_count = 0 } :: any

	return setmetatable(self, {
		__call = function(s: spy, ...)
			s.call_count += 1
			table.insert(s.calls, { ... })
			return impl and impl(...)
		end,
	})
end

local function never_called(msg: string?): () -> never
	return fn(function()
		error(msg or 'unexpected call', 2)
	end) :: any
end

-- module
return table.freeze { fn = fn, never_called = never_called }
