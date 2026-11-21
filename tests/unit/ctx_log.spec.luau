local expect = require '@test/expect'
local process = require '@lune/process'

-- tests
local run = {}

function run.should_flush_spawned_logs_grouped_after_join()
	local result = process.exec('lune', { 'run', 'tests/unit/assets/ctx_log_spawn.luau' })
	local lines = {}
	for line in result.stdout:gsub('\27%[[%d;]*m', ''):gmatch '[^\n]+' do
		local trimmed = line:match '^%s*(.-)%s*$' :: string
		if trimmed:sub(1, 1) ~= 'a' and trimmed:sub(1, 1) ~= 'b' and trimmed ~= 'done' then continue end
		table.insert(lines, trimmed)
	end

	expect.eq(result.ok, true, result.stderr)
	expect.eq(table.concat(lines, ','), 'a 1,a 2,b 1,b 2,done')
	expect.truthy(result.stdout:find 'boom', 'spawned error is logged')
end

return run
