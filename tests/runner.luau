local process = require '@lune/process'

-- ANSI helpers
local ESC = '\27['
local c = {
	reset = ESC .. '0m',
	bold = ESC .. '1m',
	dim = ESC .. '2m',
	red = ESC .. '31m',
	green = ESC .. '32m',
	yellow = ESC .. '33m',
	cyan = ESC .. '36m',
}

type spec = { [string]: () -> () }

local function first_line(s: string): string
	return (s:match '([^\n]+)') or s
end

local function run_suite(name: string, spec: spec): (number, number)
	local passed, failed = 0, 0

	-- collect and sort for stable output
	local names: { string } = {}
	for fn_name in spec do
		table.insert(names, fn_name)
	end
	table.sort(names)

	print(c.bold .. c.cyan .. '\n  ' .. name .. c.reset)

	for _, fn_name in names do
		local ok, err = xpcall(spec[fn_name] :: any, debug.traceback)
		if ok then
			passed += 1
			print(c.green .. '    ✓ ' .. c.reset .. c.dim .. fn_name .. c.reset)
		else
			failed += 1
			print(c.red .. '    ✗ ' .. fn_name .. c.reset)
			print(c.dim .. '      ' .. first_line(tostring(err)) .. c.reset)
		end
	end

	return passed, failed
end

-- ── register specs here ──────────────────────────────────────────────────────

local specs: { [string]: spec } = {
	tbl = require './unit/tbl.spec',
	sync = require './unit/sync.spec',
	['integration/round_trip'] = require './integration/round_trip.spec',
	['integration/sync'] = require './integration/sync.spec', -- requires API_KEY env var
}

-- ── run ──────────────────────────────────────────────────────────────────────

local total_passed, total_failed = 0, 0

local suite_names: { string } = {}
for name in specs do
	table.insert(suite_names, name)
end
table.sort(suite_names)

for _, name in suite_names do
	local p, f = run_suite(name, specs[name])
	total_passed += p
	total_failed += f
end

print ''
if total_failed == 0 then
	print(c.bold .. c.green .. '  ' .. total_passed .. ' passed' .. c.reset)
else
	local summary = c.bold
		.. '  '
		.. c.green
		.. total_passed
		.. ' passed'
		.. c.reset
		.. c.bold
		.. '  '
		.. c.red
		.. total_failed
		.. ' failed'
		.. c.reset
	print(summary)
end
print ''

if total_failed > 0 then process.exit(1) end
