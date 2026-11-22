local args = require '@cli/args'
local cli = require '@utils/cli'
local fs = require '@lune/fs'
local process = require '@lune/process'

local auth_guidance = require '@cli/auth_guidance'
local state_fs = require '@cli/state_fs'

-- cli
local STATE_PATH = cli.str 'cache' or 'cloud-state.yml'
local UNIVERSE = cli.num('universe', { value = 'ID', help = 'Universe to check scopes on (default: the --cache one)' })
cli.strict()

-- run
local universe_id = UNIVERSE or fs.isFile(STATE_PATH) and state_fs.load_lock(STATE_PATH).universe_id or nil
auth_guidance.print_auth(args.API_KEY, universe_id)

return process.exit(0)
