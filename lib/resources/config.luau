local cloud = require '@pkg/ro_cloud'
local http = require '@utils/http'
local tbl = require '@utils/tbl'

local base = require './base'

-- defs
export type config_type = 'json' | 'string' | 'number' | 'boolean'
export type config_data = {
	type: config_type,
	description: string?, -- read-only: open cloud drafts only take values, set it in creator hub
}
export type config_input = config_data & { conflicts: { [string]: any } }
export type config_lock = { universe_id: number, key: string, input: config_data }

-- values never live in ro-sync: creation publishes the type's zero value, tuning happens in creator hub/game
local ZERO: { [config_type]: any } = { json = {}, string = '', number = 0, boolean = false }
local TYPES: { [string]: true } = { json = true, string = true, number = true, boolean = true }

local CONFIG =
	'https://apis.roblox.com/creator-configs-public-api/v1/configs/universes/{universe_id}/repositories/InExperienceConfig'
local UNIVERSE = table.freeze { universe_id = 0 }
type universe_path = typeof(UNIVERSE)

type full_entry = { value: any, description: string? }
type full = { entries: { [string]: full_entry }? }
type draft = { draftHash: string, entries: { [string]: any }? }
type publish = { draftHash: string, message: string, deploymentStrategy: 'Immediate' | 'GradualRollout' }

local READ = { apikey = { scope = { ['universe:read'] = true :: true } } }
local WRITE = { apikey = { scope = { ['universe:write'] = true :: true } } }

local get_full = cloud.web.endpoint<<universe_path, nil, nil, full>> {
	base = `{CONFIG}/full`,
	method = 'GET',
	auth = READ,
	path = UNIVERSE,
}
local get_draft = cloud.web.endpoint<<universe_path, nil, nil, draft>> {
	base = `{CONFIG}/draft`,
	method = 'GET',
	auth = READ,
	path = UNIVERSE,
}
local patch_draft = cloud.web.endpoint<<universe_path, nil, { entries: { [string]: any } }, draft>> {
	base = `{CONFIG}/draft`,
	method = 'PATCH',
	auth = WRITE,
	path = UNIVERSE,
	content_type = 'application/json',
}
local publish_draft = cloud.web.endpoint<<universe_path, nil, publish, { configVersion: number }>> {
	base = `{CONFIG}/publish`,
	method = 'POST',
	auth = WRITE,
	path = UNIVERSE,
	content_type = 'application/json',
}

-- validation
local function parse_input(c: any, label: string)
	base.req(c, 'table', label)
	base.req(c.type, 'string', `{label}.type`)
	base.check(TYPES[c.type] ~= nil, `{label}.type must be json | string | number | boolean, got {c.type}`)
	base.opt(c.description, 'string', `{label}.description`)
	base.check(c.value == nil, `{label}.value is not synced, tune values in creator hub`)

	base.opt(c.conflicts, 'table', `{label}.conflicts`)
	c.conflicts = c.conflicts or {}
end

local function parse_lock(entry: any, label: string)
	base.req(entry.universe_id, 'number', `{label}.universe_id`)
	base.req(entry.key, 'string', `{label}.key`)

	parse_input(entry.input, `{label}.input`)
	entry.input.conflicts = nil
end

-- encoding
local function encode_input(c: config_input): config_input
	return tbl.subtraction(c, { conflicts = next(c.conflicts) == nil or nil })
end

-- diff
local function diff(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	return base.diff_fields(from, to, { 'type', 'description' })
end

-- api impl
type session = base.session

local function from_full_entry(entry: full_entry): config_data
	local kind = type(entry.value)
	return {
		type = if kind == 'table' then 'json' else kind :: any,
		description = if entry.description ~= '' then entry.description else nil,
	}
end

-- 404 means the universe never published a config / has no draft
local function try_read<R>(
	endpoint: cloud.endpoint<universe_path, nil, nil, R, any>,
	session: session,
	universe: universe_path
): R?
	local ok, result = pcall(http.call, endpoint, session, universe, nil)
	if ok then return result end

	base.check(string.match(tostring(result), '^404') ~= nil, tostring(result))
	return nil
end

local function entries_of(session: session, universe: universe_path): { [string]: full_entry }
	local full = try_read(get_full, session, universe)
	return full and full.entries or {}
end

local function list(session: session, universe: universe_path): { [string]: config_data }
	local out = {}
	for key, entry in entries_of(session, universe) do
		out[key] = from_full_entry(entry)
	end
	return out
end

-- a pending draft would be published along with ours
local function has_draft(session: session, universe: universe_path): boolean
	local draft = try_read(get_draft, session, universe)
	return draft ~= nil and next(draft.entries or {}) ~= nil
end

local function get(session: session, lock: config_lock): config_data
	local entry = entries_of(session, { universe_id = lock.universe_id })[lock.key]
		or error(`config {lock.key} no longer exists in universe {lock.universe_id}`, 0)
	return from_full_entry(entry)
end

-- raises so the reason is logged; returning an err would only show a bare push failure
local function update(_session: session, lock: config_lock, _patch: config_input): (config_data, string?)
	error(`config {lock.key}: type/description are read-only through open cloud, change them in creator hub`, 0)
end

-- adopts an existing key, otherwise publishes it with the type's zero value
local function create(session: session, ctx: { universe_id: number }, input: config_input, key: string): config_lock
	local universe = { universe_id = ctx.universe_id }
	local entry = entries_of(session, universe)[key]

	if not entry then
		base.check(
			not has_draft(session, universe),
			`universe {ctx.universe_id} has an unpublished config draft, publish or discard it before creating {key}`
		)

		local value = ZERO[input.type]
		local draft = http.call(patch_draft, session, universe, { entries = { [key] = value } })
		http.call(publish_draft, session, universe, {
			draftHash = draft.draftHash,
			message = `ro-sync: create {key}`,
			deploymentStrategy = 'Immediate',
		})
		entry = { value = value, description = nil }
	end

	return { universe_id = ctx.universe_id, key = key, input = from_full_entry(entry :: full_entry) }
end

-- module
return table.freeze {
	parse_input = parse_input,
	parse_lock = parse_lock,

	encode_input = encode_input,

	diff = diff,
	mask = base.mask,

	from_full_entry = from_full_entry,

	list = list,
	get = get,
	create = create,
	update = update,
}
