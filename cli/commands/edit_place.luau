local cli = require '@utils/cli'
local place_ref = require './place_ref'
local process = require '@lune/process'

cli.strict()
local name, ref = place_ref.resolve()

local url = `roblox-studio:1+task:EditPlace+placeId:{ref.place_id}+universeId:{ref.universe_id}`

-- run
if process.os == 'windows' then
	process.exec('', { `explorer "{url}"` }, { shell = true })
elseif process.os == 'macos' then
	process.exec('open', { url })
else
	process.exec('xdg-open', { url })
end

print(`opening {name} ({ref.place_id}) in studio`)

return process.exit(0)
