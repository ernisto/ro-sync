local cloud = require '@pkg/ro_cloud'
local http = require '@utils/http'
local serde = require '@lune/serde'
local tbl = require '@utils/tbl'

local base = require './base'

-- defs
export type config_type = 'json' | 'string' | 'number' | 'boolean'
export type config_data = {
	type: config_type,
	description: string?, -- read-only: open cloud drafts only take values, set it in creator hub
	value: any?, -- only synced when set, otherwise tuned in creator hub/game
}
export type config_input = config_data & { value_file: string?, conflicts: { [string]: any } }
export type config_lock = { universe_id: number, key: string, input: config_data }

-- configs without `value` are created with the type's zero value
local ZERO: { [config_type]: any } = { json = {}, string = '', number = 0, boolean = false }
local LUA_TYPES: { [string]: string } = { json = 'table', string = 'string', number = 'number', boolean = 'boolean' }

-- keys roblox reads from another repository than ConfigService's
-- https://create.roblox.com/docs/cloud-services/data-stores/right-to-be-forgotten#configure-automated-rtbf-via-configs-api
local REPOSITORY_OF: { [string]: cloud.config_repository } = { user_data_templates = 'DataStoresConfig' }
local REPOSITORIES: { cloud.config_repository } = { 'InExperienceConfig', 'DataStoresConfig' }

type universe_path = { universe_id: number }
type repository_path = { universe_id: number, repository: cloud.config_repository }
type full_entry = cloud.config_entry_data

local function path_of(universe_id: number, key: string): repository_path
	local repository: cloud.config_repository = REPOSITORY_OF[key] or 'InExperienceConfig'
	return { universe_id = universe_id, repository = repository }
end

-- validation
local function check_value(c: any, label: string)
	if c.value == nil then return end

	local expected = LUA_TYPES[c.type]
	base.check(type(c.value) == expected, `{label}.value must be {expected} for type {c.type}, got {type(c.value)}`)
end

local function parse_input(c: any, label: string)
	base.req(c, 'table', label)
	base.req(c.type, 'string', `{label}.type`)
	base.check(LUA_TYPES[c.type] ~= nil, `{label}.type must be json | string | number | boolean, got {c.type}`)
	base.opt(c.description, 'string', `{label}.description`)
	base.opt(c.value_file, 'string', `{label}.value_file`)
	base.check(c.value == nil or c.value_file == nil, `{label} sets both value and value_file`)
	check_value(c, label)

	base.opt(c.conflicts, 'table', `{label}.conflicts`)
	c.conflicts = c.conflicts or {}
end

local function parse_lock(entry: any, label: string, key: string)
	base.req(entry.universe_id, 'number', `{label}.universe_id`)
	entry.key = key

	parse_input(entry.input, `{label}.input`)
	entry.input.conflicts = nil
end

-- `value_file` content: json/yaml/toml decoded by extension, anything else is a string
local DECODERS: { [string]: serde.EncodeDecodeFormat } = { json = 'json', yaml = 'yaml', yml = 'yaml', toml = 'toml' }
local function load_value_file(c: config_input, content: string, label: string)
	local ext = string.match(c.value_file or '', '%.([^./]+)$') or ''
	local format: serde.EncodeDecodeFormat? = DECODERS[string.lower(ext)]
	c.value = if format then serde.decode(format, content) else content
	check_value(c, label)
end

-- encoding
local function encode_lock_entry(lock: config_lock): any
	return { universe_id = lock.universe_id, input = lock.input }
end

-- a value_file's value stays in the file
-- ponytail: cloud edits to a value_file config get overwritten by the file on the next push; write it back if that bites
local function encode_input(c: config_input): config_input
	return tbl.subtraction(c, { conflicts = next(c.conflicts) == nil or nil, value = c.value_file ~= nil or nil })
end

-- diff
local function diff(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	return base.diff_fields(from, to, { 'type', 'description', 'value' })
end

-- api impl
type session = base.session

-- values are only read back for configs that sync them
local function from_full_entry(entry: full_entry, tracks_value: boolean): config_data
	local kind = type(entry.value)
	return {
		type = if kind == 'table' then 'json' else kind :: any,
		description = if entry.description ~= '' then entry.description else nil,
		value = if tracks_value then entry.value else nil,
	}
end

local function try_read<R>(
	endpoint: cloud.endpoint<repository_path, nil, nil, R, any>,
	session: session,
	path: repository_path
): R?
	local ok, result = pcall(http.call, endpoint, session, path, nil)
	if ok then return result end

	-- 404 means the universe never published a config / has no draft
	base.check(string.match(tostring(result), '^404') ~= nil, tostring(result))
	return nil
end

local function entries_of(session: session, path: repository_path): { [string]: full_entry }
	local full = try_read(cloud.config.get_full, session, path)
	return full and full.entries or {}
end

local function list(session: session, universe: universe_path): { [string]: config_data }
	local out = {}
	for _, repository in REPOSITORIES do
		local path = { universe_id = universe.universe_id, repository = repository } :: repository_path
		for key, entry in entries_of(session, path) do
			out[key] = from_full_entry(entry, false)
		end
	end
	return out
end

-- a pending draft would be published along with ours
local function await_publish(session: session, universe_id: number, key: string, value: any, message: string)
	local path = path_of(universe_id, key)
	local pending = try_read(cloud.config.get_draft, session, path)
	base.check(
		pending == nil or next(pending.entries or {}) == nil,
		`universe {universe_id} has an unpublished config draft, publish or discard it before syncing {key}`
	)

	local draft = http.call(cloud.config.update_draft, session, path, { entries = { [key] = value } })
	http.call(cloud.config.publish, session, path, {
		draftHash = draft.draftHash,
		message = message,
		deploymentStrategy = 'Immediate',
	})
end

local function get(session: session, lock: config_lock): config_data
	local entry = entries_of(session, path_of(lock.universe_id, lock.key))[lock.key]
		or error(`config {lock.key} no longer exists in universe {lock.universe_id}`, 0)
	return from_full_entry(entry, lock.input.value ~= nil)
end

local function update(session: session, lock: config_lock, patch: config_input): (config_data, string?)
	base.check(
		patch.type == nil and patch.description == nil,
		`config {lock.key}: type/description are read-only through open cloud, change them in creator hub`
	)
	await_publish(session, lock.universe_id, lock.key, patch.value, `ro-sync: update {lock.key}`)
	return { value = patch.value } :: any
end

local function create(session: session, ctx: { universe_id: number }, input: config_input, key: string): config_lock
	local entry = entries_of(session, path_of(ctx.universe_id, key))[key]
	local tracks_value = input.value ~= nil

	if not entry or tracks_value and not base.same(entry.value, input.value) then
		local value = if tracks_value then input.value else ZERO[input.type]
		await_publish(session, ctx.universe_id, key, value, `ro-sync: create {key}`)
		entry = { value = value, description = entry and entry.description }
	end

	return { universe_id = ctx.universe_id, key = key, input = from_full_entry(entry :: full_entry, tracks_value) }
end

-- module
return table.freeze {
	parse_input = parse_input,
	parse_lock = parse_lock,
	load_value_file = load_value_file,

	encode_input = encode_input,
	encode_lock_entry = encode_lock_entry,

	diff = diff,
	mask = base.mask,

	stage = base.stage,

	list = list,
	get = get,
	create = create,
	update = update,
	delete = base.unsupported 'configs cant be deleted by ro-sync, remove them in creator hub',
}
