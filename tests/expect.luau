local function eq(actual: any, expected: any)
	if actual ~= expected then error(`expected {tostring(expected)}, got {tostring(actual)}`, 2) end
end

local function neq(actual: any, unexpected: any)
	if actual == unexpected then error(`expected value to differ from {tostring(unexpected)}`, 2) end
end

local function truthy(val: any, msg: string?)
	if not val then error(msg or `expected truthy, got {tostring(val)}`, 2) end
end

local function falsy(val: any, msg: string?)
	if val then error(msg or `expected falsy, got {tostring(val)}`, 2) end
end

local function never_called(msg: string?)
	return function(): never
		error(msg or 'unexpected call', 2)
	end
end

return table.freeze { eq = eq, neq = neq, truthy = truthy, falsy = falsy, never_called = never_called }
