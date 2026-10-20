local expect = require '@test/expect'
local sm = require '@test/sync_mock'
local state = require '@lib/state'
local sync = require '@lib/sync'
local thumbnail = require '@lib/resources/thumbnail'

local HASH_A, HASH_B = string.rep('a', 64), string.rep('b', 64)
local function file(hash: string): any
	return { hash = hash, content = buffer.create(0) }
end

local run = {}

function run.manifest_round_trips_thumbnails()
	local manifest = state.parse_manifest(buffer.fromstring [[
version: 1
owner: { user: 1 }
thumbnails:
  - file: main.png
icon:
  file: icon.png
]])
	local out = state.encode_manifest(manifest)

	expect.truthy(out:find 'main.png', 'thumbnail kept')
	expect.truthy(out:find 'icon.png', 'icon kept')
end

function run.reuploads_only_on_hash_change()
	local uploads = 0
	local api: any = {
		diff = thumbnail.diff,
		get = function()
			return nil
		end,
		create = thumbnail.create,
		update = function(_, lock: any, patch: any)
			uploads += 1
			lock.thumbnail_id += 1
			return { image_file = { hash = patch.image_file.hash, assetid = lock.thumbnail_id } }
		end,
	}
	local lock = {
		universe_id = sm.UNIVERSE_ID,
		thumbnail_id = 1,
		input = { image_file = { hash = HASH_A, assetid = 1 } },
	}
	local opts = { universe_id = sm.UNIVERSE_ID, session = nil :: any }

	local same = { key = 'main', lock = lock, input = { file = 'main.png', image_file = file(HASH_A), conflicts = {} } }
	sync.await_reconcile(api, same :: any, opts)
	expect.eq(uploads, 0)

	local changed =
		{ key = 'main', lock = lock, input = { file = 'main.png', image_file = file(HASH_B), conflicts = {} } }
	local new_lock = sync.await_reconcile(api, changed :: any, opts)
	expect.eq(uploads, 1)
	expect.eq(new_lock.thumbnail_id, 2)
	expect.eq(new_lock.input.image_file.hash, HASH_B)
end

return run
