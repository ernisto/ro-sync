local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local http = require '@utils/http'
local tbl = require '@utils/tbl'

local base = require './base'
type input_file = base.input_file
type lock_file = base.lock_file

-- defs
export type thumbnail_data<F = lock_file> = { image_file: F }
export type thumbnail_input = {
	file: string?,
	image_file: input_file?,
	conflicts: { [string]: any },
}
export type thumbnail_lock = {
	universe_id: number,
	thumbnail_id: number,
	input: thumbnail_data,
}

-- validation
local function validate_input(t: any, label: string)
	base.req(t, 'table', label)
	base.opt(t.file, 'string', `{label}.file`)

	base.opt(t.conflicts, 'table', `{label}.conflicts`)
	t.conflicts = t.conflicts or {}
end

local function validate_lock(entry: any, label: string)
	base.req(entry.universe_id, 'number', `{label}.universe_id`)
	base.req(entry.thumbnail_id, 'number', `{label}.thumbnail_id`)

	base.req(entry.input, 'table', `{label}.input`)
	entry.input.conflicts = nil
end

-- encoding
local function encode_input(t: thumbnail_input): thumbnail_input
	return tbl.subtraction(t, {
		image_file = true,
		conflicts = next(t.conflicts) == nil or nil,
	})
end

local function encode_lock_entry(t: thumbnail_lock): thumbnail_lock
	local image_file = t.input.image_file
	return {
		universe_id = t.universe_id,
		thumbnail_id = t.thumbnail_id,
		input = { image_file = image_file and { hash = image_file.hash, assetid = image_file.assetid } },
	}
end

-- diff
local function diff(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	return { image_file = base.diff_file(from.image_file, to.image_file) }
end

-- api impl
type session = base.session

local function upload(session: session, universe_id: number, file: input_file): number
	local result = http.request('POST', `games/{universe_id}/thumbnail/image`, function()
		return cloud.universe_media.upload_thumbnail(session, { universe_id = universe_id }, file.content)
	end)
	return result.targetId
end

local function get(session: session, thumbnail: thumbnail_lock): thumbnail_data?
	local result = http.request('GET', `games/{thumbnail.universe_id}/media`, function()
		return cloud.universe_media.list_thumbnails(session, { universe_id = thumbnail.universe_id })
	end)
	for _, item in result.data do
		if item.imageId == thumbnail.thumbnail_id then return { image_file = { assetid = item.imageId } } end
	end
	return nil
end

local function remove(session: session, universe_id: number, thumbnail_id: number)
	http.request('DELETE', `universes/{universe_id}/thumbnails/{thumbnail_id}`, function()
		return cloud.universe_media.delete_thumbnail(session, { universe_id = universe_id }, thumbnail_id)
	end)
end

local function update(session: session, thumbnail: thumbnail_lock, patch: thumbnail_input): thumbnail_data
	if not patch.image_file then return {} :: any end

	local id = upload(session, thumbnail.universe_id, patch.image_file)

	local ok = pcall(remove, session, thumbnail.universe_id, thumbnail.thumbnail_id)
	if not ok then ctx_log.warn(`couldnt delete old thumbnail {thumbnail.thumbnail_id}`) end

	thumbnail.thumbnail_id = id
	return { image_file = { hash = patch.image_file.hash, assetid = id } }
end

local function create(session: session, game: cloud.universe_identity, input: thumbnail_input): thumbnail_lock
	local file = input.image_file or error 'thumbnail has no image file'
	local id = upload(session, game.universe_id, file)

	return {
		universe_id = game.universe_id,
		thumbnail_id = id,
		input = { image_file = { hash = file.hash, assetid = id } },
	}
end

-- module
return table.freeze {
	validate_input = validate_input,
	validate_lock = validate_lock,

	encode_input = encode_input,
	encode_lock_entry = encode_lock_entry,

	diff = diff,

	create = create,
	get = get,
	update = update,
}
