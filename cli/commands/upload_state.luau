local args = require '@cli/args'
local cli = require '@utils/cli'
local ctx_log = require '@utils/ctx_log'
local fs = require '@lune/fs'
local process = require '@lune/process'
local serde = require '@lune/serde'
local yaml = require '@utils/yaml'

local auth_guidance = require '@cli/auth_guidance'
local state = require '@lib/state'
local state_fs = require '@cli/state_fs'

-- cli
local STATE_PATH = cli.str 'cache' or 'cloud-state.yml'
local STORE = cli.str('store', { value = 'NAME', help = 'Data store name' })
local KEY = cli.str('key', { value = 'KEY', help = 'Data store entry key' })
local SCOPE = cli.str('scope', { value = 'SCOPE', help = 'Data store scope (default: global)' })
local UNIVERSE = cli.num('universe', { value = 'ID', help = "Universe of the data store (default: the state's)" })
local REF, REFS = args.optional_files('ref', {
	value = 'FILE',
	help = 'Write a state referencing the entry to FILE (none: replace the uploaded state)',
})
cli.strict()

-- run
local content = fs.readFile(STATE_PATH)
local lock = state.parse_lock(buffer.fromstring(content))
if lock.extends then cli.fail(`{STATE_PATH} already extends another state, upload that one instead`) end

local store: state.rbxstore = {
	store = STORE or cli.fail '--store is required',
	key = KEY or cli.fail '--key is required',
	scope = SCOPE,
	universe = UNIVERSE,
}
local universe_id = UNIVERSE or lock.universe_id or cli.fail(`{STATE_PATH} has no universe_id, pass --universe`)

local session = auth_guidance.authenticate_key(args.API_KEY, args.API_KEY ~= nil, universe_id) or process.exit(1)
state_fs.await_write_store(lock, store, serde.decode('yaml', content), session)
ctx_log.str(`uploaded {STATE_PATH} to {store.store}/{store.key}`)

if REF then
	local ref_path = REFS[1] or STATE_PATH
	fs.writeFile(ref_path, yaml.encode { version = 1, universe_id = lock.universe_id, extends = { rbxstore = store } })
	ctx_log.str(`wrote {ref_path}`)
end

return process.exit(0)
