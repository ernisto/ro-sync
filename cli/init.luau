local cli = require '@utils/cli'
local process = require '@lune/process'
local c = require('@utils/ctx_log').colors

require '@cli/args' -- declare shared/global options before any dispatch/read

local ABOUT = 'Sync Roblox developer products with a YAML manifest'
local COMMANDS = {
	{ 'sync', '3-way sync of developer products (default)' },
	{ 'place load', 'Download a place as an .rbxl file' },
	{ 'place play', 'Open the place in Roblox Player' },
	{ 'place edit', 'Open the place in Roblox Studio' },
	{ 'place run', 'Run a Luau script against the place' },
}
local GROUPS: { [string]: boolean } = { place = true }

if cli.cmd 'sync' then return require '@cli/commands/sync' end
if cli.cmd('place', 'load') then return require '@cli/commands/load_place' end
if cli.cmd('place', 'play') then return require '@cli/commands/play_place' end
if cli.cmd('place', 'edit') then return require '@cli/commands/edit_place' end
if cli.cmd('place', 'run') then return require '@cli/commands/run_place' end

local cmd, sub = cli.str(1), cli.str(2)
local hint
if cmd and GROUPS[cmd] then
	hint = if sub then `unknown subcommand '{sub}' for '{cmd}'` else `command '{cmd}' needs a subcommand`
elseif cmd then
	hint = `unknown command '{cmd}'`
end

local width = 0
for _, entry in COMMANDS do
	width = math.max(width, #entry[1])
end

local lines = {}
if hint then table.insert(lines, `{c.red}{c.bold}error:{c.reset} {hint}\n`) end

table.insert(lines, ABOUT)
table.insert(lines, '')
table.insert(lines, `{c.bold}{c.yellow}Usage:{c.reset} {c.green}ro-sync{c.reset} [OPTIONS] [COMMAND]`)
table.insert(lines, '')
table.insert(lines, `{c.bold}{c.yellow}Commands:{c.reset}`)

for _, entry in COMMANDS do
	local name, desc = entry[1], entry[2]
	local pad = string.rep(' ', width - #name)
	table.insert(lines, `  {c.green}{name}{c.reset}{pad}  {c.dim}{desc}{c.reset}`)
end

print(table.concat(lines, '\n'))
process.exit(1)
