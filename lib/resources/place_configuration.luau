local cloud = require '@pkg/ro_cloud'
local http = require '@utils/http'

local base = require './base'

-- defs
export type place_configuration_input = { [string]: any, conflicts: { [string]: any } }
export type place_configuration_lock = { universe_id: number, place_id: number, input: { [string]: any } }

-- develop api fields; name/description/max players are synced by the place itself (open cloud)
local FIELDS: base.field_map = {
	social_slot_type = { 'socialSlotType', 'string' },
	custom_social_slots_count = { 'customSocialSlotsCount', 'number' },
	allow_copying = { 'allowCopying', 'boolean' },
	is_all_genres_allowed = { 'isAllGenresAllowed', 'boolean' },
	-- ponytail: allowed_gear_types skipped, GET returns ids while PATCH takes names; map them when needed
}

-- validation
local function parse_input(c: any, label: string)
	base.parse_mapped(c, FIELDS, label)
end

local function parse_lock(entry: any, label: string)
	base.req(entry, 'table', label)
	base.req(entry.universe_id, 'number', `{label}.universe_id`)
	base.req(entry.place_id, 'number', `{label}.place_id`)

	parse_input(entry.input, `{label}.input`)
	entry.input.conflicts = nil
end

-- diff
local function diff(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	return base.diff_map(from, to, FIELDS)
end

-- api impl
type session = base.session
type place_path = { place_id: number }

local function get(session: session, place: place_path): { [string]: any }
	local path = { place_id = place.place_id }
	return base.from_api(FIELDS, http.call(cloud.place_configuration.get, session, path, nil))
end

local function update(
	session: session,
	place: place_path,
	patch: place_configuration_input
): ({ [string]: any }, string?)
	local path = { place_id = place.place_id }
	return base.from_api(FIELDS, http.call(cloud.place_configuration.update, session, path, base.to_api(FIELDS, patch)))
end

-- module
return table.freeze {
	FIELDS = FIELDS,

	parse_input = parse_input,
	parse_lock = parse_lock,
	encode_input = base.encode_mapped,

	diff = diff,
	mask = base.mask,

	get = get,
	update = update,
}
