local args = require '@cli/args'
local cli = require '@utils/cli'
local ctx_log = require '@utils/ctx_log'
local fs = require '@lune/fs'
local process = require '@lune/process'

local auth_guidance = require '@cli/auth_guidance'
local codegen = require '@lib/codegen'
local state_fs = require '@cli/state_fs'

-- cli
local STATE_PATH = cli.str 'cache' or 'cloud-state.yml'
local OUTPUT = cli.str('output', { value = 'FILE', help = 'Luau module to write (default: cloud.luau)' })
	or 'cloud.luau'
local API_KEY = args.API_KEY

cli.strict()

-- run
local lock = state_fs.load_lock(STATE_PATH)
local session = nil
if lock.extends and lock.extends.rbxstore then
	session = auth_guidance.authenticate_key(API_KEY, API_KEY ~= nil, lock.universe_id) or process.exit(1)
end
state_fs.await_load_extends(lock, session)

local code = codegen.generate(lock)
if fs.isFile(OUTPUT) and fs.readFile(OUTPUT) == code then return process.exit(0) end

local dir = string.match(OUTPUT, '^(.*)/[^/]*$')
if dir and not fs.isDir(dir) then fs.writeDir(dir) end

fs.writeFile(OUTPUT, code)
ctx_log.str(`wrote {OUTPUT}`)

return process.exit(0)
