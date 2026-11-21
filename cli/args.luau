local cli = require '@utils/cli'
local env = require '@utils/env'

local GLOBAL = 'Global Options'

cli.bool('help', { aliases = { 'h' }, group = GLOBAL, help = 'print help' })
local auto_accept = cli.bool('yes', { aliases = { 'y' }, group = GLOBAL, help = 'auto-accept prompts' })
cli.str('cache', { value = 'FILE', default = 'cloud-state.yml', group = GLOBAL, help = 'lock/state file' })

-- global: caches extending an Open Cloud data store need it too
local api_key = cli.str('api-key', {
	value = 'KEY',
	group = GLOBAL,
	help = 'Open Cloud API key (default: $API_KEY)',
}) or env.is_set 'API_KEY' and env.secret.string 'API_KEY' or nil

return table.freeze {
	API_KEY = api_key,
	AUTO_ACCEPT = auto_accept,
	INTERACTIVE = not env.is_set 'CI',
}
