-- functions
local function count(tab)
	local count = 0
	for _ in tab do
		count += 1
	end
	return count
end

local function clone_intersect<T>(base: { [string]: any }, mask: T): T
	assert(type(mask) == 'table')
	local out = {}
	for k in mask do
		out[k] = base[k]
	end
	return out :: any
end

local function write_apply<T>(base: T, new: { [string]: any }): T
	assert(type(base) == 'table')
	for k, v in new do
		base[k] = v
	end
	return base
end
local function clone_apply<T>(base: T, new: { [string]: any }): T
	return write_apply(table.clone(base :: any), new) :: any
end

local function write_subtract<T>(base: T, removing: { [string]: any }): T
	assert(type(base) == 'table')
	for k in removing do
		base[k] = nil
	end
	return base
end
local function clone_subtract<T>(base: T, removing: { [string]: any }): T
	return write_subtract(table.clone(base :: any), removing) :: any
end

local function clone_filter(t: { [string]: any }, include: (string, any) -> boolean): { [string]: any }
	local out = {}
	for k, v in t do
		if include(k, v) then out[k] = v end
	end
	return out
end
local function clone_changes(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	return clone_filter(to, function(k, v)
		return v ~= from[k]
	end)
end

-- module
return table.freeze {
	subtraction = clone_subtract,
	subtract = write_subtract,

	applied = clone_apply,
	apply = write_apply,

	intersection = clone_intersect,
	filtered = clone_filter,
	changes = clone_changes,
	count = count,
}
