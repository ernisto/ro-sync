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
local CONTENT, CONTENTS = args.optional_files('content', {
	value = 'FILE',
	help = 'Write the downloaded state to FILE (none: replace the referencing state; omitted: print it)',
})
cli.strict()

-- run
local raw = serde.decode('yaml', fs.readFile(STATE_PATH))
local lock = state.parse_lock(buffer.fromstring(fs.readFile(STATE_PATH)))
local store = lock.extends and lock.extends.rbxstore or cli.fail(`{STATE_PATH} doesnt reference a data store`)
local universe_id = store.universe or lock.universe_id or cli.fail(`{STATE_PATH} has no universe_id`)

local session = auth_guidance.authenticate_key(args.API_KEY, args.API_KEY ~= nil, universe_id) or process.exit(1)
local value = state_fs.await_read_store(lock, store, session)
	or cli.fail(`data store entry {store.store}/{store.key} doesnt exist`)

-- fields the referencing state owns win, like when extending
local downloaded = table.clone(value)
for key, own in raw do
	if key ~= 'extends' then downloaded[key] = own end
end
local content = yaml.encode(downloaded)
state.parse_lock(buffer.fromstring(content))

if not CONTENT then
	print(content)
	return process.exit(0)
end

local out_path = CONTENTS[1] or STATE_PATH
fs.writeFile(out_path, content)
ctx_log.str(`wrote {out_path}`)

return process.exit(0)
