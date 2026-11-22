local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local http = require '@utils/http'
local pages = require '@utils/pages'
local tbl = require '@utils/tbl'

local base = require './base'
local place_configuration = require './place_configuration'
type input_file = base.input_file
type lock_file = base.lock_file
type api_file = base.api_file

-- defs
export type place_data<F = api_file> = {
	asset_file: F,
	display_name: string,
	description: string,
	server_size: number,
}
export type place_input = {
	file: string?,
	asset_file: input_file?,
	display_name: string?,
	description: string?,
	server_size: number?,
	configuration: place_configuration.place_configuration_input?,

	conflicts: { [string]: any },
}
export type place_lock = {
	universe_id: number,
	place_id: number,
	input: place_data<lock_file>, -- cloud doesnt provide data on creation
	configuration: place_configuration.place_configuration_lock?,
}

-- open cloud place fields
local FIELDS: base.field_map = {
	display_name = { 'displayName', 'string' },
	description = { 'description', 'string' },
	server_size = { 'serverSize', 'number' },
}

-- validation
local function parse_input(p: any, label: string)
	base.req(p, 'table', label)

	base.opt(p.file, 'string', `{label}.file`)
	base.validate_map(p, FIELDS, label)

	if p.configuration ~= nil then place_configuration.parse_input(p.configuration, `{label}.configuration`) end

	base.opt(p.conflicts, 'table', `{label}.conflicts`)
	p.conflicts = p.conflicts or {}
end

local function parse_lock(entry: any, label: string)
	base.req(entry.universe_id, 'number', `{label}.universe_id`)
	base.req(entry.place_id, 'number', `{label}.place_id`)

	parse_input(entry.input, `{label}.input`)
	entry.input.conflicts = nil

	if entry.configuration ~= nil then place_configuration.parse_lock(entry.configuration, `{label}.configuration`) end
end

local function validate(input: place_input)
	if input.file and not input.asset_file then ctx_log.warn(`couldnt find place file '{input.file}'`) end
end

-- encoding
local function encode_input(place: place_input): place_input
	return tbl.applied(
		tbl.subtraction(place, {
			asset_file = true,
			conflicts = next(place.conflicts) == nil or nil,
		}),
		{ configuration = place.configuration and place_configuration.encode_input(place.configuration) }
	)
end

local function encode_lock_entry(place: place_lock): place_lock
	local input = place.input
	local asset_file = base.lock_file_of(input.asset_file)

	return {
		universe_id = place.universe_id,
		place_id = place.place_id,
		input = tbl.applied(input, { asset_file = asset_file }),
		configuration = place.configuration,
	}
end

-- diff
local function diff(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	local out = base.diff_map(from, to, FIELDS)
	out.asset_file = base.diff_file(from.asset_file, to.asset_file)
	return out
end

-- api type
export type place_read = place_data & { universe_id: number, place_id: number }

local BASEPLATE_PLACE_ID = 95206881

local function from_place_config(data: cloud.place_configuration_data, universe_id: number): place_read
	return {
		universe_id = universe_id,
		place_id = data.id,
		display_name = data.name,
		asset_file = { assetid = data.id },
		description = data.description,
		server_size = data.maxPlayerCount,
	}
end

-- api impl
type session = base.session
type place_path = { universe_id: number, place_id: number }
type universe_path = { universe_id: number }

local function update(session: session, place: place_path, patch: place_input): (place_data, string?)
	local path = { universe_id = place.universe_id, place_id = place.place_id }
	local info = base.to_api(FIELDS, patch)
	local confirmed: { [string]: any } = {}

	local _, err1 = pcall(function()
		if next(info) == nil then return end
		confirmed = base.from_api(FIELDS, http.call(cloud.place.update_info, session, path, info))
	end :: any)

	local _, err2 = pcall(function()
		if not patch.asset_file then return end

		local content = patch.asset_file.content
		local uploaded = http.call(cloud.place.upload, session, path, content, { versionType = 'Published' })
		confirmed.asset_file =
			{ hash = patch.asset_file.hash, assetid = place.place_id, version = uploaded.versionNumber }
	end :: any)

	return confirmed :: any, err1 or err2
end

local function create(session: session, game: universe_path, place: place_input): place_lock
	local universe = { universe_id = game.universe_id }
	local result = http.call(cloud.place.create, session, universe, { templatePlaceId = BASEPLATE_PLACE_ID })

	local identity = { universe_id = game.universe_id, place_id = result.placeId }
	local data, err = update(session, identity, place)

	-- place already exists: keep the lock so next sync retries the update instead of re-creating
	if err then ctx_log.warn(`place {identity.place_id} created, but update failed: {err}`) end

	return {
		universe_id = identity.universe_id,
		place_id = identity.place_id,
		input = data :: any,
	}
end

-- versions list newest first, as `assets/<id>/versions/<n>`
local function latest_version(session: session, place_id: number): number?
	local page = http.call(cloud.asset.list_versions, session, { asset_id = place_id }, nil, { maxPageSize = 1 })
	local latest = page.assetVersions[1]
	return latest and tonumber(string.match(latest.path or '', '/versions/(%d+)$'))
end

local function get(session: session, place: place_path): place_data
	local path = { universe_id = place.universe_id, place_id = place.place_id }
	local data: any = base.from_api(FIELDS, http.call(cloud.place.get_info, session, path, nil))
	data.asset_file = { assetid = place.place_id, version = latest_version(session, place.place_id) }
	return data
end

local function list(session: session, universe: universe_path): { place_read }
	local path = { universe_id = universe.universe_id }

	local raws = pages.collect_async(function(cursor)
		local page = http.call(cloud.develop.list_universe_places, session, path, nil, { cursor = cursor })
		return page.data, page.nextPageCursor
	end)

	local reads = {}
	for _, raw in raws do
		table.insert(reads, from_place_config(raw, universe.universe_id))
	end
	return reads
end

-- module
return table.freeze {
	FIELDS = FIELDS,

	parse_input = parse_input,
	parse_lock = parse_lock,
	validate = validate,

	encode_input = encode_input,
	encode_lock_entry = encode_lock_entry,

	diff = diff,
	mask = base.mask,

	stage = base.stage,

	create = create,
	get = get,
	update = update,
	list = list,

	BASEPLATE_PLACE_ID = BASEPLATE_PLACE_ID,
	delete = base.unsupported 'places cant be deleted through open cloud',
}
