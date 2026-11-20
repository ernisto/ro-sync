local serde = require '@lune/serde'

-- defs
local SIGNATURE = '\137PNG\r\n\26\n'
local DIRECTIONS = { { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }

type chunk = { kind: string, data: string }

-- crc32
local CRC_TABLE = {}
for n = 0, 255 do
	local c = n
	for _ = 1, 8 do
		c = if bit32.band(c, 1) == 1 then bit32.bxor(0xEDB88320, bit32.rshift(c, 1)) else bit32.rshift(c, 1)
	end
	CRC_TABLE[n] = c
end

local function crc32(s: string): number
	local c = 0xFFFFFFFF
	for i = 1, #s do
		c = bit32.bxor(CRC_TABLE[bit32.band(bit32.bxor(c, string.byte(s, i)), 0xFF)], bit32.rshift(c, 8))
	end
	return bit32.bxor(c, 0xFFFFFFFF)
end

-- chunks
local function read_chunks(png: string): { chunk }?
	if string.sub(png, 1, 8) ~= SIGNATURE then return nil end

	local chunks, pos = {}, 9
	while pos <= #png do
		local len, kind = string.unpack('>I4c4', png, pos)
		table.insert(chunks, { kind = kind, data = string.sub(png, pos + 8, pos + 7 + len) })
		pos += 12 + len
	end
	return chunks
end

local function write_chunk(kind: string, data: string): string
	return string.pack('>I4', #data) .. kind .. data .. string.pack('>I4', crc32(kind .. data))
end

-- filters
local function paeth(a: number, b: number, c: number): number
	local p = a + b - c
	local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
	return if pa <= pb and pa <= pc then a elseif pb <= pc then b else c
end

local function unfilter(raw: string, w: number, h: number): buffer
	local stride = w * 4
	local px = buffer.create(stride * h)

	for y = 0, h - 1 do
		local filter = string.byte(raw, y * (stride + 1) + 1)
		local src, row = y * (stride + 1) + 2, y * stride

		for x = 0, stride - 1 do
			local v = string.byte(raw, src + x)
			local a = if x >= 4 then buffer.readu8(px, row + x - 4) else 0
			local b = if y > 0 then buffer.readu8(px, row - stride + x) else 0
			local c = if x >= 4 and y > 0 then buffer.readu8(px, row - stride + x - 4) else 0

			local pred = if filter == 1
				then a
				elseif filter == 2 then b
				elseif filter == 3 then (a + b) // 2
				elseif filter == 4 then paeth(a, b, c)
				else 0
			buffer.writeu8(px, row + x, (v + pred) % 256)
		end
	end
	return px
end

local function filter_none(px: buffer, w: number, h: number): string
	local stride = w * 4
	local rows = table.create(h)
	for y = 0, h - 1 do
		rows[y + 1] = '\0' .. buffer.readstring(px, y * stride, stride)
	end
	return table.concat(rows)
end

-- bleed: transparent pixels take the average color of their nearest non-transparent neighbors (port of asphalt)
local function bleed_pixels(px: buffer, w: number, h: number): boolean
	local sampled, visited = buffer.create(w * h), buffer.create(w * h)
	local queue = {}

	local function alpha(i: number): number
		return buffer.readu8(px, i * 4 + 3)
	end

	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local i = y * w + x
			if alpha(i) ~= 0 then
				buffer.writeu8(sampled, i, 1)
				buffer.writeu8(visited, i, 1)
				continue
			end

			for _, d in DIRECTIONS do
				local nx, ny = x + d[1], y + d[2]
				if nx < 0 or ny < 0 or nx >= w or ny >= h or alpha(ny * w + nx) == 0 then continue end

				buffer.writeu8(visited, i, 1)
				table.insert(queue, i)
				break
			end
		end
	end
	if #queue == 0 then return false end

	while #queue > 0 do
		local next_queue = {}
		for _, i in queue do
			local x, y = i % w, i // w
			local r, g, b, n = 0, 0, 0, 0

			for _, d in DIRECTIONS do
				local nx, ny = x + d[1], y + d[2]
				if nx < 0 or ny < 0 or nx >= w or ny >= h then continue end

				local j = ny * w + nx
				if buffer.readu8(sampled, j) == 1 then
					r += buffer.readu8(px, j * 4)
					g += buffer.readu8(px, j * 4 + 1)
					b += buffer.readu8(px, j * 4 + 2)
					n += 1
				elseif buffer.readu8(visited, j) == 0 then
					buffer.writeu8(visited, j, 1)
					table.insert(next_queue, j)
				end
			end

			n = math.max(n, 1)
			buffer.writeu8(px, i * 4, r // n)
			buffer.writeu8(px, i * 4 + 1, g // n)
			buffer.writeu8(px, i * 4 + 2, b // n)
		end
		for _, i in queue do
			buffer.writeu8(sampled, i, 1)
		end
		queue = next_queue
	end
	return true
end

-- ponytail: only 8-bit RGBA non-interlaced pngs are bled, others upload untouched; add palette/gray decoding if those show fringes
local function bleed(png: string): string
	local chunks = read_chunks(png)
	if not chunks or chunks[1].kind ~= 'IHDR' then return png end

	local w, h, depth, color, _, _, interlace = string.unpack('>I4I4BBBBB', chunks[1].data)
	if depth ~= 8 or color ~= 6 or interlace ~= 0 then return png end

	local idat = {}
	for _, chunk in chunks do
		if chunk.kind == 'IDAT' then table.insert(idat, chunk.data) end
	end

	local px = unfilter(serde.decompress('zlib', table.concat(idat)), w, h)
	if not bleed_pixels(px, w, h) then return png end

	local out, wrote_idat = { SIGNATURE }, false
	for _, chunk in chunks do
		if chunk.kind ~= 'IDAT' then
			table.insert(out, write_chunk(chunk.kind, chunk.data))
		elseif not wrote_idat then
			wrote_idat = true
			table.insert(out, write_chunk('IDAT', serde.compress('zlib', filter_none(px, w, h))))
		end
	end
	return table.concat(out)
end

-- module
return table.freeze {
	bleed = bleed,
	crc32 = crc32,
}
