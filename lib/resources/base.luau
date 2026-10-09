local cloud = require '@pkg/ro_cloud'
local serde = require '@lune/serde'

-- types
export type session = cloud.session
export type owner = { user: nil, group: number } | { user: number, group: nil }
export type input_file = { hash: string, content: buffer, assetid: nil }
export type lock_file = { hash: string?, content: nil, assetid: number? }
export type api_file = { hash: nil, content: nil, assetid: number }
export type file = input_file | lock_file | api_file

-- validation
local function check(cond: boolean, msg: string)
	if not cond then error(msg, 0) end
end

local function req(value: any, kind: string, label: string)
	check(type(value) == kind, `{label} must be {kind}, got {type(value)}`)
end

local function opt(value: any, kind: string, label: string)
	check(value == nil or type(value) == kind, `{label} must be {kind} or nil, got {type(value)}`)
end

local function string_map(value: any, label: string): { [string]: any }
	if value == nil then return {} end
	req(value, 'table', label)

	for key, entry in value do
		check(type(key) == 'string', `{label} keys must be strings, got {type(key)}`)
		req(entry, 'table', `{label}.{tostring(key)}`)
	end
	return value
end

local function validate_owner(owner: any, label: string)
	req(owner, 'table', label)

	local has_user, has_group = owner.user ~= nil, owner.group ~= nil
	check(has_user ~= has_group, `{label} must set exactly one of user/group`)

	if has_user then req(owner.user, 'number', `{label}.user`) end
	if has_group then req(owner.group, 'number', `{label}.group`) end
end

local function flatten_group(
	input: any,
	group: string,
	fields: { [string]: true },
	validate: (any, string) -> (),
	label: string
)
	local nested = input[group]
	if nested == nil then return end

	req(nested, 'table', `{label}.{group}`)

	for field in fields do
		if nested[field] == nil then continue end

		validate(nested[field], `{label}.{group}.{field}`)
		input[field] = nested[field]
	end
	input[group] = nil
end

-- diff
local function diff_fields(from: { [string]: any }, to: { [string]: any }, fields: { string }): { [string]: any }
	local out = {}
	for _, field in fields do
		-- a field missing on the receiving side (e.g. no hash to compare) counts as no change
		if to[field] ~= nil and from[field] ~= to[field] then out[field] = to[field] end
	end
	return out
end

local function diff_file(from: file, to: file): file?
	local from_hash = if from then from.hash else nil
	local to_hash = if to then to.hash else nil
	return if to_hash ~= nil and from_hash ~= to_hash then to else nil
end

local function json_of(v: any): string?
	return if type(v) == 'table' and next(v) == nil then nil else serde.encode('json', v)
end

-- encoding
local function encode_map(map: { [string]: any }, encode: (any) -> any)
	local out = {}
	for key, entry in map do
		out[key] = encode(entry)
	end
	return if next(out) == nil then nil else out
end

-- module
return table.freeze {
	check = check,
	req = req,
	opt = opt,
	string_map = string_map,
	validate_owner = validate_owner,
	flatten_group = flatten_group,

	diff_fields = diff_fields,
	diff_file = diff_file,
	json_of = json_of,

	encode_map = encode_map,
}
