local cli = require '@utils/cli'
local env = require '@utils/env'
local fs = require '@lune/fs'
local serde = require '@lune/serde'

export type ref = { place_id: number, universe_id: number }

cli.str('place', { positional = true, required = true, help = 'place name from the lock file' })
local state = cli.some {
	remote = cli.str 'remote-cache',
	file = cli.path 'cache',
}
local source = state.remote or state.file or cli.fail 'missing state source'

-- functions
local function resolve(): (string, ref)
	local ok, lock = pcall(function()
		return serde.decode('yaml', fs.readFile(source))
	end)
	if not ok then cli.fail(`cant read state '{source}'`) end

	local name = cli.str 'place' or cli.fail 'place name arg missing'
	local place = lock.places and lock.places[name] or cli.fail(`no place '{name}' in state`)
	return name, { place_id = place.place_id, universe_id = place.universe_id or lock.universe_id }
end

local function api_key(): string
	return cli.str 'api-key' or env.secret.string 'API_KEY'
end

return table.freeze { resolve = resolve, api_key = api_key }
