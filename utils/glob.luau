-- path globs with `*`, `?`, `**` and `{a,b}`; paths use `/`

local function expand_braces(pattern: string): { string }
	local head, alts, tail = string.match(pattern, '^(.-){([^{}]*)}(.*)$')
	if not head or not alts or not tail then return { pattern } end

	local out = {}
	for _, alt in string.split(alts, ',') do
		for _, expanded in expand_braces(head .. alt .. tail) do
			table.insert(out, expanded)
		end
	end
	return out
end

local function segment_pattern(segment: string): string
	local escaped = string.gsub(segment, '[%^%$%(%)%%%.%[%]%+%-]', '%%%0')
	return '^' .. string.gsub(string.gsub(escaped, '%*', '[^/]*'), '%?', '[^/]') .. '$'
end

local function match_segments(pattern: { string }, path: { string }, pi: number, si: number): boolean
	local segment = pattern[pi]
	if segment == nil then return path[si] == nil end
	if segment == '**' then
		for skip = si, #path + 1 do
			if match_segments(pattern, path, pi + 1, skip) then return true end
		end
		return false
	end
	return path[si] ~= nil
		and string.match(path[si], segment_pattern(segment)) ~= nil
		and match_segments(pattern, path, pi + 1, si + 1)
end

local function is_match(glob: string, path: string): boolean
	local segments = string.split(path, '/')
	for _, pattern in expand_braces(glob) do
		if match_segments(string.split(pattern, '/'), segments, 1, 1) then return true end
	end
	return false
end

-- literal dirs before the first wildcard segment
local function root_of(glob: string): string
	local root = {}
	for _, segment in string.split(glob, '/') do
		if string.find(segment, '[%*%?{%[]') then break end
		table.insert(root, segment)
	end
	return table.concat(root, '/')
end

return table.freeze {
	is_match = is_match,
	root_of = root_of,
}
