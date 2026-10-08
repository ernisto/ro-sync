local cloud = require '@pkg/ro_cloud'
local http = require '@utils/http'
local tbl = require '@utils/tbl'

local base = require './base'
type input_file = base.input_file
type lock_file = base.lock_file
type api_file = base.api_file

-- defs
export type place_data<F = api_file> = {
	asset_file: F,
	display_name: string,
	description: string,
	server_size: number,
	social_slot_type: string,
	custom_social_slots_count: number,
	allow_copying: boolean,
	is_all_genres_allowed: boolean,
	-- allowed_gear_types: { string }?, -- TODO: how do i map number to string ? what string value should be ?
}
export type place_input = {
	file: string?,
	asset_file: input_file?,
	display_name: string?,
	description: string?,
	server_size: number?,
	allow_copying: boolean?,
	social_slot_type: string?,
	is_all_genres_allowed: boolean?,
	custom_social_slots_count: number?,

	conflicts: { [string]: any },
}
export type place_lock = {
	universe_id: number,
	place_id: number,
	input: place_data<lock_file>, -- cloud doesnt provide data on creation
}

-- validation
local function validate_input(p: place_input, label: string)
	base.req(p, 'table', label)
	base.opt(p.file, 'string', `{label}.file`)
	base.opt(p.display_name, 'string', `{label}.display_name`)
	base.opt(p.description, 'string', `{label}.description`)
	base.opt(p.server_size, 'number', `{label}.server_size`)

	-- develop place_configuration fields
	base.opt(p.social_slot_type, 'string', `{label}.social_slot_type`)
	base.opt(p.custom_social_slots_count, 'number', `{label}.custom_social_slots_count`)
	base.opt(p.allow_copying, 'boolean', `{label}.allow_copying`)
	base.opt(p.is_all_genres_allowed, 'boolean', `{label}.is_all_genres_allowed`)
	-- base.opt(p.allowed_gear_types, 'table', `{label}.allowed_gear_types`)

	base.opt(p.conflicts, 'table', `{label}.conflicts`)
	p.conflicts = p.conflicts or {}
end

local function validate_lock(entry: place_lock, label: string)
	base.req(entry.universe_id, 'number', `{label}.universe_id`)
	base.req(entry.place_id, 'number', `{label}.place_id`)

	validate_input(entry.input :: any, `{label}.input`);
	(entry :: any).input.conflicts = nil
end

-- encoding
local function encode_input(place: place_input): place_input
	return tbl.subtraction(place, {
		asset_file = true,
		conflicts = next(place.conflicts) == nil or nil,
	})
end

local function encode_lock_entry(place: place_lock): place_lock
	local input = place.input
	local asset_file = if input.asset_file
		then { hash = input.asset_file.hash, assetid = input.asset_file.assetid }
		else nil

	return {
		universe_id = place.universe_id,
		place_id = place.place_id,
		input = tbl.applied(input, { asset_file = asset_file }),
	}
end

-- diff
local function diff(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	local out = base.diff_fields(from, to, {
		'display_name',
		'description',
		'server_size',
		'social_slot_type',
		'custom_social_slots_count',
		'allow_copying',
		'is_all_genres_allowed',
	})

	out.asset_file = base.diff_file(from.asset_file, to.asset_file)
	return out
end

local function mask(read: place_data, input: place_input): place_input
	local out: any = diff(read, input)
	out.conflicts = input.conflicts or {}

	if input.file ~= nil then out.file = input.file end
	return out
end

-- api type
export type place_read = place_data & { universe_id: number, place_id: number }

local BASEPLATE_PLACE_ID = 95206881

local function from_place_config(data: cloud.place_data): place_data
	return {
		display_name = data.name,
		asset_file = { assetid = data.id },
		description = data.description,
		allow_copying = data.allowCopying,
		server_size = data.maxPlayerCount,
		social_slot_type = data.socialSlotType,
		is_all_genres_allowed = data.isAllGenresAllowed,
		custom_social_slots_count = data.customSocialSlotsCount,
		-- allowed_gear_types = data.allowedGearTypes,
	}
end

local function to_place_config_params(patch: place_input): cloud.place_patch
	return {
		name = patch.display_name,
		description = patch.description,
		allowCopying = patch.allow_copying,
		maxPlayerCount = patch.server_size,
		socialSlotType = patch.social_slot_type,
		isAllGenresAllowed = patch.is_all_genres_allowed,
		customSocialSlotsCount = patch.custom_social_slots_count,
		-- allowedGearTypes = patch.allowed_gear_types,
	}
end

-- api impl
type session = base.session

local function update(session: session, place: cloud.place_identity, patch: place_input): (place_data, string?)
	local config = to_place_config_params(patch)
	local confirmed: { [string]: any } = {}

	local _, err1 = pcall(function()
		if next(config) == nil then return end

		confirmed = from_place_config(http.request('PATCH', `places/{place.place_id}`, function()
			return cloud.place_configuration.update(session, { place_id = place.place_id }, config)
		end))
		confirmed.asset_file = nil
	end :: any)

	local _, err2 = pcall(function()
		if not patch.asset_file then return end

		http.request('POST', `places/{place.place_id}/versions`, function()
			return cloud.place.upload(session, place, patch.asset_file.content, true)
		end)
		confirmed.asset_file = { hash = patch.asset_file.hash, assetid = place.place_id }
	end :: any)

	return confirmed, err1 or err2
end

local function create(session: session, game: cloud.universe_identity, place: place_input): place_lock
	local result = http.request('POST', 'assets (Place)', function()
		return cloud.place.create(session, { universe_id = game.universe_id }, { templatePlaceId = BASEPLATE_PLACE_ID })
	end)

	local identity = { universe_id = game.universe_id, place_id = result.placeId }
	local data = update(session, identity, place)

	return {
		universe_id = identity.universe_id,
		place_id = identity.place_id,
		input = data or {} :: any,
	}
end

local function get(session: session, place: cloud.place_identity): place_data
	return from_place_config(http.request('GET', `places/{place.place_id}`, function()
		return cloud.place_configuration.get(session, { place_id = place.place_id })
	end))
end

local function list(session: session, universe: cloud.universe_identity): { cloud.place_data }
	local places = {}
	local cursor: string? = nil
	repeat
		local page = http.request('GET', `universes/{universe.universe_id}/places`, function()
			return cloud.develop.list_universe_places(session, universe, { cursor = cursor })
		end)

		for _, place in page.data do
			table.insert(places, place)
		end
		local next_cursor = page.nextPageCursor
		cursor = if next_cursor == '' or next_cursor == cursor then nil else next_cursor
	until cursor == nil

	return places
end

-- module
return table.freeze {
	validate_input = validate_input,
	validate_lock = validate_lock,

	encode_input = encode_input,
	encode_lock_entry = encode_lock_entry,

	diff = diff,
	mask = mask,

	from_place_config = from_place_config,
	to_place_config_params = to_place_config_params,

	create = create,
	get = get,
	update = update,
	list = list,
}
