local state = require './state'

-- what a file resolves to: its uploaded asset or a stand-in; keyed by path relative to the glob root
export type file_content = { asset_id: number?, uri: string?, keyframe_root: { string }? }
export type asset_files = { [string]: file_content }

-- functions
local function is_identifier(key: string): boolean
	return string.match(key, '^[%a_][%w_]*$') ~= nil
end

local function key_of(key: string): string
	return if is_identifier(key) then key else string.format('[%q]', key)
end

local function sorted_keys(t: { [string]: any }): { string }
	local keys = {}
	for key in t do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- resources (not assets): each entry is `{ <id_field>, data }`, one exported type per kind
type kind = { field: string, type_name: string, id_field: string }
local function kind(field: string, type_name: string, id_field: string): kind
	return table.freeze { field = field, type_name = type_name, id_field = id_field }
end
local KINDS: { kind } = table.freeze {
	kind('places', 'place', 'place_id'),
	kind('products', 'product', 'product_id'),
	kind('passes', 'pass', 'pass_id'),
}

-- local files and sync bookkeeping, meaningless at runtime
local IDENTITY: { [string]: true } = { universe_id = true, place_id = true, product_id = true, pass_id = true }
local function is_runtime_field(key: string): boolean
	return key ~= 'conflicts'
		and key ~= 'file'
		and key ~= 'icon'
		and not IDENTITY[key]
		and string.match(key, '_file$') == nil
end

local function runtime_data(entry: { [string]: any }): { [string]: any }
	local data = if entry.stage then entry.stage.data else entry.input or {}
	local out = {}
	for key, value in data do
		if is_runtime_field(key) then out[key] = value end
	end
	return out
end

local function literal(value: any): string
	if type(value) == 'string' then return string.format('%q', value) end
	if type(value) ~= 'table' then return tostring(value) end

	local items = {}
	if value[1] ~= nil then
		for _, item in value do
			table.insert(items, literal(item))
		end
	else
		for _, key in sorted_keys(value) do
			table.insert(items, `{key_of(key)} = {literal(value[key])}`)
		end
	end
	return if #items == 0 then '{}' else `\{ {table.concat(items, ', ')} }`
end

local function luau_type(value: any): string
	if type(value) ~= 'table' then return type(value) end
	return if value[1] ~= nil then '{ any }' else '{ [string]: any }'
end

-- every field seen across the kind's entries, optional; mixed value types widen to any
local function emit_type(out: { string }, kind: kind, locks: { [string]: any })
	local fields: { [string]: string } = {}
	for _, entry in locks do
		for key, value in runtime_data(entry) do
			local seen = fields[key]
			fields[key] = if seen == nil or seen == luau_type(value) then luau_type(value) else 'any'
		end
	end

	local items = {}
	for _, key in sorted_keys(fields) do
		table.insert(items, `{key}: {fields[key]}?`)
	end
	local data = if #items == 0 then '{}' else `\{ {table.concat(items, ', ')} }`
	table.insert(out, `export type {kind.type_name} = \{ {kind.id_field}: number, data: {data} }\n`)
end

-- entries not created yet get ids -1, -2, ... (unique in the module, never a real id)
local function emit_resources(out: { string }, kind: kind, locks: { [string]: any }, next_staged_id: () -> number)
	table.insert(out, `\t{kind.field} = \{\n`)
	for _, key in sorted_keys(locks) do
		local entry = locks[key]
		local id = entry[kind.id_field] or next_staged_id()
		table.insert(out, `\t\t{key_of(key)} = \{ {kind.id_field} = {id}, data = {literal(runtime_data(entry))} },\n`)
	end
	table.insert(out, '\t},\n')
end

-- { 'ReplicatedStorage', 'Animations', 'walk' } -> game:GetService("ReplicatedStorage"):FindFirstChild("Animations"):FindFirstChild("walk")
local function instance_expr(names: { string }): string
	local out = { `game:GetService({string.format('%q', names[1])})` }
	for i = 2, #names do
		table.insert(out, `:FindFirstChild({string.format('%q', names[i])})`)
	end
	return table.concat(out)
end

-- `parts`: the file's path under the glob root, extension stripped
local function content_expr(entry: file_content, parts: { string }): string
	if entry.asset_id then return `Content.fromUri("rbxassetid://{entry.asset_id}")` end

	local keyframe_root = entry.keyframe_root
	if not keyframe_root then return `Content.fromUri("{entry.uri}")` end

	local names = table.clone(keyframe_root)
	table.move(parts, 1, #parts, #names + 1, names)
	return `Content.fromUri(KeyframeSequenceProvider:RegisterKeyframeSequence({instance_expr(names)}))`
end

local function asset_tree(assets: asset_files): { [string]: any }
	local root: { [string]: any } = {}
	for path, entry in assets do
		local parts = string.split(path, '/')
		parts[#parts] = string.gsub(parts[#parts], '%.[^.]*$', '')

		local node: { [string]: any } = root
		for i = 1, #parts - 1 do
			if type(node[parts[i]]) ~= 'table' then node[parts[i]] = {} end
			node = node[parts[i]]
		end
		node[parts[#parts]] = content_expr(entry, parts)
	end
	return root
end

local function uses_keyframes(assets: asset_files): boolean
	for _, entry in assets do
		if entry.keyframe_root and not entry.asset_id then return true end
	end
	return false
end

-- leaves are Luau expressions, tables are folders
local function emit_assets(out: { string }, node: { [string]: any }, depth: number)
	local pad = string.rep('\t', depth)
	for _, key in sorted_keys(node) do
		local child = node[key]
		if type(child) == 'string' then
			table.insert(out, `{pad}{key_of(key)} = {child},\n`)
		else
			table.insert(out, `{pad}{key_of(key)} = \{\n`)
			emit_assets(out, child, depth + 1)
			table.insert(out, `{pad}},\n`)
		end
	end
end

local function generate(lock: state.lock, files: asset_files?): string
	local assets = files or {}
	local out = {
		'-- This file is automatically @generated by ro-sync.\n',
		'-- It is not intended for manual editing.\n',
	}
	if uses_keyframes(assets) then
		table.insert(out, 'local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")\n\n')
	end

	local resources = lock :: any
	for _, kind in KINDS do
		emit_type(out, kind, resources[kind.field])
	end
	table.insert(out, '\n')

	local staged_id = 0
	local function next_staged_id(): number
		staged_id -= 1
		return staged_id
	end

	table.insert(out, 'return {\n')
	table.insert(out, `\tuniverse_id = {lock.universe_id},\n`)
	for _, kind in KINDS do
		emit_resources(out, kind, resources[kind.field], next_staged_id)
	end

	table.insert(out, '\tassets = {\n')
	emit_assets(out, asset_tree(assets), 2)
	table.insert(out, '\t},\n}\n')
	return table.concat(out)
end

-- module
return table.freeze { generate = generate }
