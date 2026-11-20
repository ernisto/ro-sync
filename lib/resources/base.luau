local cloud = require '@pkg/ro_cloud'
local serde = require '@lune/serde'
local tbl = require '@utils/tbl'

-- types
export type session = cloud.session
export type owner = { user: nil, group: number } | { user: number, group: nil }
export type input_file = { hash: string, content: buffer, assetid: nil }
export type lock_file = { hash: string?, content: nil, assetid: number? }
export type api_file = { hash: nil, content: nil, assetid: number }
export type file = input_file | lock_file | api_file

export type field_spec = { any }
export type field_map = { [string]: field_spec }

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

local function list(value: any, label: string): { any }
	if value == nil then return {} end
	req(value, 'table', label)

	for i, entry in value do
		check(type(i) == 'number', `{label} must be a list`)
		req(entry, 'table', `{label}[{i}]`)
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

local function flatten_group(input: any, group: string, fields: { [string]: true }, label: string)
	local nested = input[group]
	if nested == nil then return end

	req(nested, 'table', `{label}.{group}`)
	for field in fields do
		if nested[field] ~= nil then input[field] = nested[field] end
	end
	input[group] = nil
end

local function validate_map(input: { [string]: any }, map: field_map, label: string)
	for field, spec in map do
		local value, nested = input[field], spec[3]
		opt(value, spec[2], `{label}.{field}`)
		if value == nil or not nested then continue end

		if value[1] == nil then
			validate_map(value, nested, `{label}.{field}`)
			continue
		end
		for i, entry in value do
			req(entry, 'table', `{label}.{field}[{i}]`)
			validate_map(entry, nested, `{label}.{field}[{i}]`)
		end
	end
end

local function parse_mapped(input: any, map: field_map, label: string)
	req(input, 'table', label)
	validate_map(input, map, label)

	opt(input.conflicts, 'table', `{label}.conflicts`)
	input.conflicts = input.conflicts or {}
end

-- diff
local function json_of(v: any): string?
	return if type(v) == 'table' and next(v) == nil then nil else serde.encode('json', v)
end

local function same(a: any, b: any): boolean
	if type(a) == 'table' or type(b) == 'table' then return json_of(a) == json_of(b) end
	return a == b
end

local function diff_fields(from: { [string]: any }, to: { [string]: any }, fields: { string }): { [string]: any }
	-- a field missing on the receiving side (e.g. no hash to compare) counts as no change
	local out = {}
	for _, field in fields do
		if to[field] ~= nil and not same(from[field], to[field]) then out[field] = to[field] end
	end
	return out
end

local function diff_map(from: { [string]: any }, to: { [string]: any }, map: field_map): { [string]: any }
	local out = {}
	for field in map do
		if to[field] ~= nil and not same(from[field], to[field]) then out[field] = to[field] end
	end
	return out
end

local function diff_file(from: file, to: file): file?
	local from_hash = if from then from.hash else nil
	local to_hash = if to then to.hash else nil
	return if to_hash ~= nil and from_hash ~= to_hash then to else nil
end

local function mask<T>(_read: { [string]: any }, input: T & { conflicts: { [string]: any }? }): T
	local out: any = table.clone(input :: any)
	out.conflicts = (input :: any).conflicts or {}
	return out
end

-- api mapping
local function remap(value: any, map: field_map, to_api: boolean): any
	if type(value) ~= 'table' then return value end

	local out = {}
	if value[1] ~= nil then
		for i, entry in value do
			out[i] = remap(entry, map, to_api)
		end
		return out
	end

	for field, spec in map do
		local api, nested = spec[1], spec[3]
		local v = value[if to_api then field else api]
		out[if to_api then api else field] = if nested then remap(v, nested, to_api) else v
	end
	return out
end

local function from_api(map: field_map, data: any): { [string]: any }
	return remap(data, map, false)
end

local function to_api(map: field_map, patch: { [string]: any }): any
	return remap(patch, map, true)
end

-- encoding
local function encode_mapped<T>(input: T & { conflicts: { [string]: any } }): T?
	local out = tbl.subtraction(input :: any, { conflicts = next(input.conflicts) == nil or nil })
	return if next(out) == nil then nil else out
end

local function lock_file_of(f: file?): lock_file?
	return if f then { hash = f.hash, assetid = f.assetid } else nil
end

local function encode_map(map: { [any]: any }, encode: (any) -> any)
	local out = {}
	for key, entry in map do
		out[key] = encode(entry)
	end
	return if next(out) == nil then nil else out
end

-- api
local unsupported_methods: { [any]: true } = setmetatable({}, { __mode = 'k' }) :: any

-- crud method a backend doesnt offer: fails loud at the caller with the reason
local function unsupported(reason: string): (...any) -> never
	local method = function(): never
		error(reason, 2)
	end
	unsupported_methods[method] = true
	return method
end

-- whether a resource method really reaches its backend (not an `unsupported` stub)
local function supports(method: any): boolean
	return method ~= nil and not unsupported_methods[method]
end

-- stage
-- staged view for codegen: `stage.data` is the lock input (last cloud state, the template) with the manifest
-- input over it; a resource not created yet stages without lock fields (no id)
local function stage(input: { [string]: any }?, lock: { [string]: any }?, _content_dir: string?): { [string]: any }
	local template = if lock then lock.input else {}
	local data = tbl.applied(template, tbl.subtraction(input or {}, { conflicts = true }))

	-- identity (universe_id, product_id, ...) lives on the lock entry, never in its data
	if lock then
		for key in lock do
			if string.match(key, '_id$') then data[key] = nil end
		end
	end

	return tbl.applied(lock or {}, { stage = { data = data } })
end

-- module
return table.freeze {
	check = check,
	req = req,
	opt = opt,
	string_map = string_map,
	list = list,
	validate_owner = validate_owner,
	flatten_group = flatten_group,
	validate_map = validate_map,
	parse_mapped = parse_mapped,

	same = same,
	diff_fields = diff_fields,
	diff_map = diff_map,
	diff_file = diff_file,
	mask = mask,
	json_of = json_of,

	from_api = from_api,
	to_api = to_api,

	lock_file_of = lock_file_of,
	encode_map = encode_map,
	encode_mapped = encode_mapped,

	unsupported = unsupported,
	supports = supports,
	stage = stage,
}
