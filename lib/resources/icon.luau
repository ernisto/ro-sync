local cloud = require '@pkg/ro_cloud'
local http = require '@utils/http'

local base = require './base'
local thumbnail = require './thumbnail'
type input_file = base.input_file

-- defs
export type icon_input = thumbnail.thumbnail_input
export type icon_lock = { universe_id: number, input: thumbnail.thumbnail_data }

-- validation
local function validate_lock(entry: any, label: string)
	base.req(entry.universe_id, 'number', `{label}.universe_id`)
	base.req(entry.input, 'table', `{label}.input`)
	entry.input.conflicts = nil
end

-- encoding
local function encode_lock_entry(t: icon_lock): icon_lock
	local image_file = t.input.image_file
	return {
		universe_id = t.universe_id,
		input = { image_file = image_file and { hash = image_file.hash, assetid = image_file.assetid } },
	}
end

-- api impl
type session = base.session

local function upload(session: session, universe_id: number, file: input_file): thumbnail.thumbnail_data
	local result = http.call(cloud.universe_media.upload_icon, session, { universe_id = universe_id }, file.content)
	return { image_file = { hash = file.hash, assetid = result.targetId } }
end

-- no endpoint to read the current icon; cloud state = lock state
local function get(_session: session, _icon: icon_lock): thumbnail.thumbnail_data?
	return nil
end

local function update(session: session, icon: icon_lock, patch: icon_input): thumbnail.thumbnail_data
	if not patch.image_file then return {} :: any end
	return upload(session, icon.universe_id, patch.image_file)
end

local function create(session: session, game: { universe_id: number }, input: icon_input): icon_lock
	local file = input.image_file or error 'icon has no image file'
	return { universe_id = game.universe_id, input = upload(session, game.universe_id, file) }
end

-- module
return table.freeze {
	validate_input = thumbnail.validate_input,
	validate_lock = validate_lock,

	encode_input = thumbnail.encode_input,
	encode_lock_entry = encode_lock_entry,

	diff = thumbnail.diff,

	create = create,
	get = get,
	update = update,
}
