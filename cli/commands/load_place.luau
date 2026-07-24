local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local fs = require '@lune/fs'
local place_ref = require './place_ref'
local process = require '@lune/process'

-- cli
cli.str('api-key', { value = 'KEY', help = 'Open Cloud API key (default: $API_KEY)' })

local output = cli.str('output', { value = 'FILE', required = true, help = 'destination .rbxl path' })
	or cli.fail '--output <file> arg missing'
cli.strict()

local name, ref = place_ref.resolve()
local api_key = place_ref.api_key()

-- run
local session = cloud.auth.apikey.login(api_key)
local res = cloud.place.download(session, { place_id = ref.place_id })
assert(res.ok, res.message)

local dir = output:match '(.*)[/\\].+$'
if dir then fs.writeDir(dir) end

fs.writeFile(output, res.body)
print(`downloaded {name} ({ref.place_id}) -> {output}`)

return process.exit(0)
