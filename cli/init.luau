local cli = require '@utils/cli'
local process = require '@lune/process'
local c = require('@utils/ctx_log').colors
local authed_http = require '@cli/auth_guidance/http'
local http = require '@utils/http'

local args = require '@cli/args' -- declare shared/global options before any dispatch/read
if args.INTERACTIVE then http.call = authed_http.call end

local ABOUT = 'Sync Roblox developer products with a YAML manifest'
local COMMANDS = table.freeze {
	{
		words = { 'sync' },
		run = function()
			return require '@cli/commands/sync'
		end,
		help = '3-way sync of developer products (default)',
	},
	{
		words = { 'place', 'load' },
		run = function()
			return require '@cli/commands/load_place'
		end,
		help = 'Download a place as an .rbxl file',
	},
	{
		words = { 'place', 'play' },
		run = function()
			return require '@cli/commands/play_place'
		end,
		help = 'Open the place in Roblox Player',
	},
	{
		words = { 'place', 'edit' },
		run = function()
			return require '@cli/commands/edit_place'
		end,
		help = 'Open the place in Roblox Studio',
	},
	{
		words = { 'place', 'run' },
		run = function()
			return require '@cli/commands/run_place'
		end,
		help = 'Run a Luau script against the place',
	},
}

-- dispatch
for _, command in COMMANDS do
	if cli.cmd(table.unpack(command.words)) then return command.run() end
end

-- no command: help; unknown command: error + help
local function is_group(word: string): boolean
	for _, command in COMMANDS do
		if #command.words > 1 and command.words[1] == word then return true end
	end
	return false
end

local cmd, sub = cli.str(1), cli.str(2)
local hint = if cmd == nil
	then nil
	elseif not is_group(cmd) then `unknown command '{cmd}'`
	elseif sub then `unknown subcommand '{sub}' for '{cmd}'`
	else `command '{cmd}' needs a subcommand`

local width = 0
for _, command in COMMANDS do
	width = math.max(width, #table.concat(command.words, ' '))
end

local lines = {
	ABOUT,
	'',
	`{c.bold}{c.yellow}Usage:{c.reset} {c.green}ro-sync{c.reset} [OPTIONS] [COMMAND]`,
	'',
	`{c.bold}{c.yellow}Commands:{c.reset}`,
}

for _, command in COMMANDS do
	local name = table.concat(command.words, ' ')
	local pad = string.rep(' ', width - #name)
	table.insert(lines, `  {c.green}{name}{c.reset}{pad}  {c.dim}{command.help}{c.reset}`)
end

if hint then table.insert(lines, 1, `{c.red}{c.bold}error:{c.reset} {hint}\n`) end

print(table.concat(lines, '\n'))
process.exit(if hint then 1 else 0)
