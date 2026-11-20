local expect = require '@test/expect'
local fs = require '@lune/fs'
local roblox = require '@lune/roblox'
local serde = require '@lune/serde'

local asset = require '@lib/resources/asset'
local asset_files = require '@lib/asset_files'
local http = require '@utils/http'
local png = require '@utils/png'
local state = require '@lib/state'

local TMP = 'tests/unit/tmp_assets'

local function chunk(kind: string, data: string): string
	return string.pack('>I4', #data) .. kind .. data .. string.pack('>I4', png.crc32(kind .. data))
end

-- 8-bit RGBA png, one filter-0 row per entry of `rows` ({ r, g, b, a } per pixel)
local function make_png(rows: { { { number } } }): string
	local raw = {}
	for _, row in rows do
		table.insert(raw, '\0')
		for _, px in row do
			table.insert(raw, string.char(px[1], px[2], px[3], px[4]))
		end
	end
	local ihdr = string.pack('>I4I4BBBBB', #rows[1], #rows, 8, 6, 0, 0, 0)
	return '\137PNG\r\n\26\n'
		.. chunk('IHDR', ihdr)
		.. chunk('IDAT', serde.compress('zlib', table.concat(raw)))
		.. chunk('IEND', '')
end

local function pixels(file: string): string
	local len = string.unpack('>I4', file, 34)
	return serde.decompress('zlib', string.sub(file, 42, 41 + len))
end

local run = {}

function run.build_indexes_paths_by_hash()
	local entries: any = {
		{ path = 'a/sounds/Shoe 1.ogg', rel = 'sounds/Shoe 1.ogg', hash = 'h1' },
		{ path = 'a/copy.ogg', rel = 'copy.ogg', hash = 'h1' },
		{ path = 'a/hover.ogg', rel = 'hover.ogg', hash = 'h2' },
		{ path = 'a/failed.png', rel = 'failed.png', hash = 'new' },
		{ path = 'a/skip.png', rel = 'skip.png', hash = 'missing' },
	}
	local lock: any = {
		h1 = { id = 11, paths = { 'sounds/Shoe 1.ogg' } },
		old = { id = 3, paths = { 'failed.png' } },
		gone = { id = 4, paths = { 'deleted.png' } },
	}
	local out = asset_files.build(entries, lock, { h2 = { id = 22 }, h1 = { uri = 'rbxasset://x' } })

	expect.eq(table.concat(out.h1.paths, ','), 'copy.ogg,sounds/Shoe 1.ogg', 'duplicates share the hash entry')
	expect.eq(out.h2.id, 22)
	expect.eq(out.h1.id, 11, 'stand-in never replaces an id')
	expect.eq(out.old.paths[1], 'failed.png', 'failed re-upload keeps the old id')
	expect.eq(out.gone.id, 4, 'removed files keep their id')
	expect.eq(#out.gone.paths, 0)
	expect.eq(out.missing, nil)
end

function run.bleed_fills_transparent_neighbors()
	local file = make_png { { { 200, 100, 50, 255 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } } }
	local bled = png.bleed(file)

	expect.eq(pixels(bled), '\0' .. string.char(200, 100, 50, 255, 200, 100, 50, 0, 200, 100, 50, 0))
end

function run.bleed_keeps_opaque_png_untouched()
	local file = make_png { { { 1, 2, 3, 255 } } }
	expect.eq(png.bleed(file), file)
end

function run.detects_animation_models()
	local anim = roblox.serializeModel { roblox.Instance.new 'KeyframeSequence' }
	local model = roblox.serializeModel { roblox.Instance.new 'Part' }

	expect.eq(asset_files.kind_of('a.rbxm', anim).asset_type, 'Animation')
	expect.eq(asset_files.kind_of('a.rbxm', model).asset_type, 'Model')
	expect.eq(asset_files.kind_of('a.OGG', '').asset_type, 'Audio')
end

function run.lock_round_trips_assets()
	local lock = state.parse_lock(
		buffer.fromstring 'version: 1\nuniverse_id: 1\nassets: { abc: { id: 12, paths: [ui/btn.png] } }\n'
	)
	expect.eq((lock.assets :: any).abc.id, 12)

	local again = state.parse_lock(buffer.fromstring(state.encode_lock(lock)))
	expect.eq((again.assets :: any).abc.paths[1], 'ui/btn.png')
end

function run.sync_uploads_only_new_hashes()
	fs.writeDir(TMP .. '/ui')
	fs.writeFile(TMP .. '/ui/a.png', 'aaa')
	fs.writeFile(TMP .. '/ui/dup.png', 'aaa')
	fs.writeFile(TMP .. '/b.ogg', 'bbb')
	fs.writeFile(TMP .. '/notes.txt', 'ignored')

	local known = serde.hash('blake3', 'bbb')
	local lock: any = { [known] = { id = 7, paths = { 'renamed.ogg' } } }
	local bodies = {}

	local call = http.call
	http.call = function(endpoint: any, _, _, body: any): any
		if endpoint.method == 'POST' then
			table.insert(bodies, body)
			return { path = 'operations/op1', done = false }
		end
		return { done = true, response = { assetId = '99' } }
	end
	local ok, out = pcall(asset.create :: any, nil, { group = 5 }, { files = TMP .. '/**' }, lock)
	http.call = call
	fs.removeDir(TMP)
	expect.truthy(ok, out)

	expect.eq(#bodies, 1, 'duplicate content and known hash are not uploaded')
	expect.eq(bodies[1].mime, 'image/png')
	expect.truthy(bodies[1].request:find '"groupId":"5"' ~= nil)

	expect.eq(table.concat(out[known].paths, ','), 'b.ogg', 'renamed file reuses id by hash')
	expect.eq(out[serde.hash('blake3', 'aaa')].id, 99)
	expect.eq(table.concat(out[serde.hash('blake3', 'aaa')].paths, ','), 'ui/a.png,ui/dup.png')
end

function run.stage_copies_files_without_id()
	fs.writeDir(TMP .. '/src')
	fs.writeFile(TMP .. '/src/a.png', 'aaa')
	fs.writeFile(TMP .. '/src/b.ogg', 'bbb')

	local a, b = serde.hash('blake3', 'aaa'), serde.hash('blake3', 'bbb')
	local lock: any = { [b] = { id = 7, paths = { 'b.ogg' } } }
	local ok, out: any = pcall(asset.stage, { files = TMP .. '/src/**' }, lock, TMP .. '/content')
	local copied = fs.isFile(`{TMP}/content/ro-sync/{a}.png`)
	local skipped = fs.isFile(`{TMP}/content/ro-sync/{b}.ogg`)
	fs.removeDir(TMP)
	expect.truthy(ok, out)

	expect.truthy(copied)
	expect.falsy(skipped, 'uploaded assets are not staged')
	expect.eq(out[a].uri, `rbxasset://ro-sync/{a}.png`)
	expect.eq(out[a].id, nil)
	expect.eq(out[b].id, 7)

	local relock = state.parse_lock(buffer.fromstring(`version: 1\nuniverse_id: 1\nassets: \{ {a}: \{ uri: x } }\n`))
	expect.eq((relock.assets :: any)[a].uri, 'x', 'staged entries parse without id')
end

function run.stage_points_animations_at_their_game_folder()
	local anim = roblox.serializeModel { roblox.Instance.new 'KeyframeSequence' }
	fs.writeDir(TMP .. '/src/npc')
	fs.writeFile(TMP .. '/src/npc/walk.rbxm', anim)

	local hash = serde.hash('blake3', anim)
	local input = { files = TMP .. '/src/**', animations = 'ReplicatedStorage.Animations' }
	local ok, out: any = pcall(asset.stage, input, {}, TMP .. '/content')
	local copied = fs.isFile(`{TMP}/content/ro-sync/{hash}.rbxm`)
	fs.removeDir(TMP)
	expect.truthy(ok, out)

	expect.falsy(copied, 'animations are registered from the game, not copied')
	expect.eq(table.concat(out[hash].keyframe_root, '.'), 'ReplicatedStorage.Animations')
	expect.eq(out[hash].paths[1], 'npc/walk.rbxm')
end

return run
