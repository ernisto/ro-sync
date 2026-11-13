local cli = require '@utils/cli'
local open_url = require '@utils/open_url'
local place_ref = require './place_ref'
local process = require '@lune/process'

cli.strict()
local name, ref = place_ref.resolve()

local url = `roblox-studio:1+task:EditPlace+placeId:{ref.place_id}+universeId:{ref.universe_id}`

-- run
open_url(url)

print(`opening {name} ({ref.place_id}) in studio`)

return process.exit(0)
