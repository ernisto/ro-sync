local cli = require '@utils/cli'
local open_url = require '@utils/open_url'
local place_ref = require './place_ref'
local process = require '@lune/process'
local serde = require '@lune/serde'

-- cli
local data = cli.str('data', { value = 'JSON', help = 'launch data passed to the place (JSON)' })
cli.strict()

local name, ref = place_ref.resolve()

-- functions
local function encode(s: string): string
	return (s:gsub('[^%w%-_%.~]', function(ch)
		return string.format('%%%02X', string.byte(ch))
	end))
end

-- run
local url = `roblox://experiences/start?placeId={ref.place_id}`
if data then
	local ok = pcall(function()
		return serde.decode('json', data)
	end)
	if not ok then error(`--data must be valid JSON, got: {data}`) end
	url ..= `&launchData={encode(data)}`
end

open_url(url)

print(`launching {name} ({ref.place_id}) in player`)

return process.exit(0)
