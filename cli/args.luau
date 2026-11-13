local cli = require '@utils/cli'
local env = require '@utils/env'

local GLOBAL = 'Global Options'

cli.bool('help', { aliases = { 'h' }, group = GLOBAL, help = 'print help' })
local auto_accept = cli.bool('yes', { aliases = { 'y' }, group = GLOBAL, help = 'auto-accept prompts' })
cli.str('cache', { value = 'FILE', default = 'cloud-state.yml', group = GLOBAL, help = 'lock/state file' })
cli.str('remote-cache', { value = 'FILE', group = GLOBAL, help = 'remote state snapshot' })

return table.freeze {
	AUTO_ACCEPT = auto_accept,
	INTERACTIVE = not env.str 'CI',
}
