local process = require '@lune/process'
local c = require('@utils/ctx_log').colors

type ArgKind = 'positional' | 'flag' | 'option' | 'variadic'
type ArgOptions = {
	help: string?,
	aliases: { string }?,
	value: string?,
	default: string?,
	required: boolean?,
	hidden: boolean?,
	group: string?,
	positional: boolean?,
}
type ArgSpec = {
	name: string,
	kind: ArgKind,
	options: ArgOptions,
}

local options: { [string]: string } = {}
local flags: { [string]: boolean } = {}
local positional: { string } = {}
local forwarded: { string } = {}

local specs: { ArgSpec } = {}
local by_name: { [string]: ArgSpec } = {}
local by_alias: { [string]: ArgSpec } = {}
local about: string?

local ESCAPES: { [string]: string } = { ['\\'] = '\\', ['"'] = '"', ["'"] = "'", n = '\n', t = '\t' }

local function unquote(s: string): string
	local first = string.sub(s, 1, 1)
	if (first ~= '"' and first ~= "'") or string.sub(s, -1) ~= first then return s end
	return (string.gsub(string.sub(s, 2, -2), '\\(.)', ESCAPES))
end

-- raw tokens up to `--`; everything after `--` is forwarded verbatim
local raw: { string } = {}
do
	local i = 1
	while i <= #process.args do
		local a = process.args[i]
		if a == '--' then
			table.move(process.args, i + 1, #process.args, 1, forwarded)
			break
		end
		table.insert(raw, a)
		i += 1
	end
end

-- binding is deferred until first access so declared specs (aliases, kinds)
-- can drive whether a short/long token takes a value or is a bare flag
local function spec_of(key: string): ArgSpec?
	return by_name[key] or by_alias[key]
end

local parsed = false
local function ensure(): ()
	if parsed then return end
	parsed = true

	local n = #raw
	local i = 1
	while i <= n do
		local a = raw[i]

		-- long: --name, --name value, --name=value
		if string.sub(a, 1, 2) == '--' then
			local rest = string.sub(a, 3)
			local eq = string.find(rest, '=', 1, true)
			if eq then
				options[string.sub(rest, 1, eq - 1)] = unquote(string.sub(rest, eq + 1))
			else
				local spec = spec_of(rest)
				local next = raw[i + 1]
				if spec and spec.kind == 'flag' then
					flags[rest] = true
				elseif next and string.sub(next, 1, 1) ~= '-' then
					options[rest] = unquote(next)
					i += 1
				else
					flags[rest] = true
				end
			end
		-- short: -f, clustered -abc, or an option alias taking a value (-c val / -cval)
		elseif string.sub(a, 1, 1) == '-' and #a > 1 then
			local j = 2
			while j <= #a do
				local ch = string.sub(a, j, j)
				local spec = spec_of(ch)
				if spec and spec.kind == 'option' then
					local inline = string.sub(a, j + 1)
					if #inline > 0 then
						options[ch] = unquote(inline)
					else
						local next = raw[i + 1]
						if next then
							options[ch] = unquote(next)
							i += 1
						end
					end
					break
				end
				flags[ch] = true
				j += 1
			end
		else
			table.insert(positional, unquote(a))
		end

		i += 1
	end
end

-- resolve a canonical name from either its name or an alias
local function canon(key: string): string
	local spec = by_alias[key]
	return if spec then spec.name else key
end

-- read a parsed value under the canonical name or any of its aliases
local function value(name: string): string?
	local spec = by_name[name]
	if options[name] ~= nil then return options[name] end
	if spec then
		for _, a in spec.options.aliases or {} :: { string } do
			if options[a] ~= nil then return options[a] end
		end
		return spec.options.default
	end
	return nil
end

local function raised(name: string): boolean
	if flags[name] then return true end
	local spec = by_name[name]
	if spec then
		for _, a in spec.options.aliases or {} :: { string } do
			if flags[a] then return true end
		end
	end
	return false
end

-- how many leading positionals were matched as command words (see `cmd`)
local cmd_offset = 0

-- declared positionals are read by name, in declaration order, after commands
local function positional_index(name: string): number?
	local n = 0
	for _, spec in specs do
		if spec.kind == 'positional' then
			n += 1
			if spec.name == name then return n end
		end
	end
	return nil
end

-- trail of string-keyed reads so `some` can name the group it was handed
local reads: { { key: string, present: boolean } } = {}
local function see(key: string, v: string?): string?
	table.insert(reads, { key = key, present = v ~= nil })
	return v
end

-- keys the command actually asked for; `strict` rejects anything else parsed
local used: { [string]: boolean } = {}

-- defined below; referenced by the early error helpers so `--help` always wins
local help: (name: string, formatter: ((string) -> string)?) -> ()
local program: (name: string?) -> string

-- register a bare spec the first time a key is read, so `help` can list it
local function infer(key: string, kind: ArgKind): ()
	if by_name[key] or by_alias[key] then return end
	local spec: ArgSpec = { name = key, kind = kind, options = {} }
	table.insert(specs, spec)
	by_name[key] = spec
end

-- full spec from an accessor's `opts`; upgrades an earlier `infer`d bare spec
local function declare(name: string, kind: ArgKind, opts: ArgOptions): ()
	local spec = by_name[name]
	if spec then
		spec.kind = kind
		spec.options = opts
	else
		local fresh: ArgSpec = { name = name, kind = kind, options = opts }
		spec = fresh
		table.insert(specs, fresh)
		by_name[name] = fresh
	end
	for _, a in opts.aliases or {} :: { string } do
		by_alias[a] = spec
	end
end

-- when `--help`/`-h` is present, show help and exit instead of erroring
local function help_gate(): ()
	ensure()
	if flags.help or flags.h then
		help(program(nil))
		process.exit(0)
	end
end

-- user error surfaced from arg parsing: clean exit, no stack trace
local function fail(msg: string): never
	help_gate()
	print(`{c.red}{c.bold}error:{c.reset} {msg}\n\nFor more information, try '{c.green}--help{c.reset}'.`)
	return process.exit(1)
end

-- upper-cased value placeholder for a key, e.g. `remote-state` -> `REMOTE_STATE`
local function metavar(key: string): string
	return string.upper((string.gsub(key, '-', '_')))
end

-- accessors ---------------------------------------------------------------
-- an `opts` arg declares the spec (help/aliases/group) and skips the `some`
-- trail; a bare read joins the trail so `some` can name its group.
-- value-expecting reads treat a bare `--key` flag (no value) as an error
local function str(key: string | number, opts: ArgOptions?): string?
	ensure()
	if type(key) == 'number' then return positional[key] end
	used[key] = true
	if opts then declare(key, if opts.positional then 'positional' else 'option', opts) end
	local pindex = positional_index(key)
	if pindex then
		local v = positional[cmd_offset + pindex]
		return if opts then v else see(key, v)
	end
	local name = canon(key)
	if not opts then infer(name, 'option') end
	if value(name) == nil and raised(name) then
		fail(`a value is required for {c.green}--{key} <{metavar(key)}>{c.reset} but none was supplied`)
	end
	local v = value(name)
	return if opts then v else see(key, v)
end
local function num(key: string | number, opts: ArgOptions?): number?
	return tonumber(str(key, opts))
end
local function uint(key: string | number, opts: ArgOptions?): number?
	local val = num(key, opts)
	return val and val // 1
end
-- alias of `str` that names a filesystem path (intent + help rendering)
local function path(key: string, opts: ArgOptions?): string?
	return str(key, opts)
end
local function bool(key: string, opts: ArgOptions?): boolean
	ensure()
	used[key] = true
	if opts then
		declare(key, 'flag', opts)
	else
		infer(canon(key), 'flag')
	end
	return raised(canon(key))
end

-- match leading positionals against command words; records depth on success
local function cmd(...: string): boolean
	ensure()
	local names = { ... }
	for i, n in names do
		if positional[i] ~= n then return false end
	end
	cmd_offset = #names
	return true
end

-- declaration -------------------------------------------------------------
local function describe(text: string): ()
	about = text
end

-- help --------------------------------------------------------------------
local function placeholder(spec: ArgSpec): string
	if spec.kind == 'flag' then return '' end
	return ` <{spec.options.value or string.upper((string.gsub(spec.name, '-', '_')))}>`
end

local function usage(name: string): string
	local parts = { name }

	local has_opts = false
	for _, spec in specs do
		if spec.kind ~= 'positional' and spec.kind ~= 'variadic' and not spec.options.hidden then
			has_opts = true
			break
		end
	end
	if has_opts then table.insert(parts, '[OPTIONS]') end

	-- required options are surfaced explicitly, jj-style
	for _, spec in specs do
		if spec.options.hidden then continue end
		if spec.kind == 'option' and spec.options.required then
			table.insert(parts, `<--{spec.name}{placeholder(spec)}>`)
		end
	end

	for _, spec in specs do
		if spec.kind == 'positional' and not spec.options.hidden then
			table.insert(parts, if spec.options.required then `<{spec.name}>` else `[{spec.name}]`)
		end
	end
	for _, spec in specs do
		if spec.kind == 'variadic' and not spec.options.hidden then
			table.insert(parts, if spec.options.required then `<{spec.name}...>` else `[{spec.name}...]`)
		end
	end

	return table.concat(parts, ' ')
end

-- render the left column: `-a, --name <VALUE>`, long names aligned when no short
local function invocation(spec: ArgSpec): string
	local short = ''
	local longs = {}
	for _, a in spec.options.aliases or {} :: { string } do
		if #a == 1 then
			short = `-{a}, `
		else
			table.insert(longs, `--{a}`)
		end
	end
	if short == '' then short = '    ' end -- pad to the width of a `-x, ` short flag

	table.insert(longs, if #spec.name == 1 then `-{spec.name}` else `--{spec.name}`)
	return short .. table.concat(longs, ', ') .. placeholder(spec)
end

function help(name: string, formatter: ((string) -> string)?): ()
	local fmt = formatter or function(s: string): string
		return s
	end

	if about then
		print(fmt(about))
		print ''
	end

	local u = usage(name)
	local painted = `{c.green}{name}{c.reset}{string.sub(u, #name + 1)}`
	print(fmt(`{c.bold}{c.yellow}Usage:{c.reset} {painted}`))

	-- group flags/options, keeping declaration order within a group
	local groups: { string } = {}
	local seen: { [string]: { ArgSpec } } = {}
	for _, spec in specs do
		if spec.options.hidden or spec.kind == 'positional' or spec.kind == 'variadic' then continue end
		local g = spec.options.group or 'Options'
		if not seen[g] then
			seen[g] = {}
			table.insert(groups, g)
		end
		table.insert(seen[g], spec)
	end

	-- plain `Options` first, `Global Options` last, everything else between
	local function rank(g: string): number
		return if g == 'Options' then 0 elseif g == 'Global Options' then 2 else 1
	end
	table.sort(groups, function(a, b)
		return rank(a) < rank(b)
	end)

	-- align help text across every visible option
	local width = 0
	for _, spec in specs do
		if spec.options.hidden or spec.kind == 'positional' or spec.kind == 'variadic' then continue end
		width = math.max(width, #invocation(spec))
	end

	for _, g in groups do
		print ''
		print(fmt(`{c.bold}{c.yellow}{g}:{c.reset}`))
		for _, spec in seen[g] do
			local left = invocation(spec)
			local pad = string.rep(' ', width - #left)
			local default = if spec.options.default then ` {c.dim}[default: {spec.options.default}]{c.reset}` else ''
			print(fmt(`  {c.green}{left}{c.reset}{pad}  {c.dim}{spec.options.help or ''}{c.reset}{default}`))
		end
	end
end

-- validation --------------------------------------------------------------
local function known(key: string): boolean
	return by_name[key] ~= nil or by_alias[key] ~= nil
end

-- how a required arg is spelled back to the user, clap-style
local function descriptor(spec: ArgSpec): string
	if spec.kind == 'positional' then return `<{spec.name}>` end
	if spec.kind == 'variadic' then return `<{spec.name}...>` end
	return `--{spec.name}{placeholder(spec)}`
end

-- bad args are user error, not a bug: print clean and exit, no stack trace
local function abort(body: string, name: string?): never
	help_gate()
	local out = `{c.red}{c.bold}error:{c.reset} {body}`
	if name then
		out ..= `\n\n{c.bold}{c.yellow}Usage:{c.reset} {usage(name)}`
	end
	out ..= `\n\nFor more information, try '{c.green}--help{c.reset}'.`
	print(out)
	return process.exit(1)
end

local function validate(name: string?): ()
	ensure()

	-- reject anything not declared (skip entirely when no specs registered so
	-- callers that don't declare args keep the permissive behaviour)
	if #specs > 0 then
		for key in options do
			if not known(key) then abort(`unexpected argument '{if #key == 1 then '-' else '--'}{key}' found`, name) end
		end
		for key in flags do
			if not known(key) then abort(`unexpected argument '{if #key == 1 then '-' else '--'}{key}' found`, name) end
		end
	end

	-- collect every missing required arg, reported together
	local missing: { string } = {}
	for _, spec in specs do
		if not spec.options.required then continue end
		local present
		if spec.kind == 'positional' then
			local pi = positional_index(spec.name)
			present = pi ~= nil and positional[cmd_offset + pi] ~= nil
		elseif spec.kind == 'variadic' then
			present = #positional > cmd_offset
		else
			present = value(spec.name) ~= nil or raised(spec.name)
		end
		if not present then table.insert(missing, descriptor(spec)) end
	end

	if #missing > 0 then
		local body = 'the following required arguments were not provided:'
		for _, d in missing do
			body ..= `\n  {c.green}{d}{c.reset}`
		end
		abort(body, name)
	end
end

-- require at least one accessor in the group to be present; returns it as-is.
-- nil-valued fields drop out of the table, so keys come from the `reads` trail
-- (call `some` right after a clear point so the trail holds only its accessors).
local function some<T>(group: T): T
	local keys: { string } = {}
	local any = false
	for _, r in reads do
		table.insert(keys, `{c.green}--{r.key}{c.reset}`)
		any = any or r.present
	end
	table.clear(reads)

	if not any then fail(`provide one of {table.concat(keys, ', ')}`) end
	return group
end

-- program name from the matched command words, e.g. `ro-sync place load`
function program(name: string?): string
	if name then return name end
	local words = { 'ro-sync' }
	for i = 1, cmd_offset do
		table.insert(words, positional[i])
	end
	return table.concat(words, ' ')
end

-- reject any parsed arg the command never asked for (via an accessor or `arg`)
local function strict(name: string?): ()
	help_gate()

	local function check(key: string)
		if not used[key] and not known(key) then
			abort(`unexpected argument '{if #key == 1 then '-' else '--'}{key}' found`, name)
		end
	end
	for key in options do
		check(key)
	end
	for key in flags do
		check(key)
	end
end

return table.freeze {
	str = str,
	num = num,
	uint = uint,
	path = path,
	bool = bool,
	cmd = cmd,
	some = some,
	fail = fail,
	strict = strict,
	forwarded = forwarded,

	describe = describe,
	validate = validate,
	usage = usage,
	help = help,
}
