local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local fs = require '@lune/fs'
local place_ref = require './place_ref'
local process = require '@lune/process'
local stdio = require '@lune/stdio'
local task = require '@lune/task'

-- cli
cli.str('api-key', { value = 'KEY', help = 'Open Cloud API key (default: $API_KEY)' })
cli.str('script-path', { value = 'FILE', help = 'path to a Luau file to run' })
cli.str('script', { value = 'CODE', help = 'inline Luau source to run' })

local poll_rate = cli.num('poll-rate', { value = 'SECS', default = '3', help = 'seconds between task polls' }) or 3
local timeout = cli.num('timeout', { value = 'SECS', help = 'task timeout in seconds' })
local version = cli.num('version', { value = 'N', help = 'place version to run against' })

local script = cli.some {
	path = cli.str 'script-path',
	code = cli.str 'script',
}
cli.strict()

local name, ref = place_ref.resolve()
local api_key = place_ref.api_key()
local code = script.code or fs.readFile(script.path :: string)
local last_state

-- functions
local function poll(session, identity)
	while true do
		task.wait(poll_rate)

		local res = cloud.luau_task_exec.get(session, identity)
		if not res.ok then
			print(`{stdio.color 'yellow'}failed to poll task ({res.code}): {res.message}{stdio.color 'reset'}`)
			continue
		end

		local data = res.body
		if data.state ~= 'PROCESSING' and data.state ~= 'QUEUED' then return data end

		if data.state ~= last_state then
			stdio.write(`{stdio.style 'dim'}-- {data.state} --{stdio.style 'reset'}\n`)
			last_state = data.state
		end
	end
end
local function print_logs(session, identity)
	local res = cloud.luau_task_exec.list_logs(session, identity, { view = 'FLAT', max_page_size = 10_000 })
	assert(res.ok, res.message)

	for _, log in res.body.luauExecutionSessionTaskLogs do
		for _, msg in log.messages do
			print(msg)
		end
	end
end

-- run
local session = cloud.auth.apikey.login(api_key)
local identity = { universe_id = ref.universe_id, place_id = ref.place_id, version = version }

stdio.write(`{stdio.style 'dim'}running on {name} ({ref.place_id})...{stdio.style 'reset'}\n`)
local create = cloud.luau_task_exec.create(session, identity, { script = code, timeout = timeout })
if not create.ok then
	print(`{stdio.color 'red'}failed to create task ({create.code}): {create.message}{stdio.color 'reset'}`)
	return process.exit(1)
end

last_state = create.body.state
local done = poll(session, create.body)

print_logs(session, done)
if done.state == 'FAILED' then
	local err = done.error
	print(`{stdio.color 'red'}[{err.code}] {err.message or ''}{stdio.color 'reset'}`)
	return process.exit(1)
end

return process.exit(0)
