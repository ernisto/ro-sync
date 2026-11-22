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
		help = '3-way merge of the manifests, the cache and Roblox cloud; only --push writes to cloud',
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
	{
		words = { 'state', 'upload' },
		run = function()
			return require '@cli/commands/upload_state'
		end,
		help = 'Upload the state file to a data store entry, --ref writes a state referencing it',
	},
	{
		words = { 'state', 'download' },
		run = function()
			return require '@cli/commands/download_state'
		end,
		help = 'Download the data store entry a state file references, --content writes it',
	},
	{
		words = { 'codegen' },
		run = function()
			return require '@cli/commands/codegen'
		end,
		help = 'Write a Luau module with the cached universe, place, product, pass and asset ids',
	},
}

-- dispatch
for _, command in COMMANDS do
	if not cli.cmd(table.unpack(command.words)) then continue end

	cli.about(command.help)
	return command.run()
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
