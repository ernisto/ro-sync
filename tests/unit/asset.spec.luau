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
		buffer.fromstring 'version: 1\nuniverse_id: 1\nassets: { abc: { asset_id: 12, universe: 1, owner: { group: 5 } } }\n'
	)
	expect.eq((lock.assets :: any).abc.asset_id, 12)

	local again: any = state.parse_lock(buffer.fromstring(state.encode_lock(lock)))
	expect.eq(again.assets.abc.universe, 1)
	expect.eq(again.assets.abc.owner.group, 5)
end

function run.sync_uploads_only_new_hashes()
	fs.writeDir(TMP .. '/ui')
	fs.writeFile(TMP .. '/ui/a.png', 'aaa')
	fs.writeFile(TMP .. '/ui/dup.png', 'aaa')
	fs.writeFile(TMP .. '/b.ogg', 'bbb')
	fs.writeFile(TMP .. '/notes.txt', 'ignored')

	local known = serde.hash('blake3', 'bbb')
	local lock: any = { [known] = { asset_id = 7 }, gone = { asset_id = 4 } }
	local bodies = {}

	local call = http.call
	http.call = function(endpoint: any, _, _, body: any): any
		if endpoint.method == 'POST' then
			table.insert(bodies, body)
			return { path = 'operations/op1', done = false }
		end
		return { done = true, response = { assetId = '99' } }
	end
	local origin = { universe = 3, owner = { group = 5 } }
	local ok, out = pcall(asset.create :: any, nil, origin, { files = TMP .. '/**' }, lock)
	http.call = call
	fs.removeDir(TMP)
	expect.truthy(ok, out)

	expect.eq(#bodies, 1, 'duplicate content and known hash are not uploaded')
	expect.eq(bodies[1].mime, 'image/png')
	expect.truthy(bodies[1].request:find '"groupId":"5"' ~= nil)

	expect.eq(out[known].asset_id, 7, 'renamed file reuses asset by hash')
	expect.eq(out.gone.asset_id, 4, 'removed files keep their asset')
	local new = out[serde.hash('blake3', 'aaa')]
	expect.eq(new.asset_id, 99)
	expect.eq(new.universe, 3)
	expect.eq(new.owner.group, 5)
end

function run.stage_copies_files_without_asset()
	fs.writeDir(TMP .. '/src')
	fs.writeFile(TMP .. '/src/a.png', 'aaa')
	fs.writeFile(TMP .. '/src/b.ogg', 'bbb')

	local a, b = serde.hash('blake3', 'aaa'), serde.hash('blake3', 'bbb')
	local lock: any = { [b] = { asset_id = 7 } }
	local ok, out: any = pcall(asset.stage, { files = TMP .. '/src/**' }, lock, TMP .. '/content')
	local copied = fs.isFile(`{TMP}/content/ro-sync/{a}.png`)
	local skipped = fs.isFile(`{TMP}/content/ro-sync/{b}.ogg`)
	fs.removeDir(TMP)
	expect.truthy(ok, out)

	expect.truthy(copied)
	expect.falsy(skipped, 'uploaded assets are not staged')
	expect.eq(out[a].uri, `rbxasset://ro-sync/{a}.png`)
	expect.eq(out[b], nil)
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
end

return run
