local fs = require '@lune/fs'
local process = require '@lune/process'

-- vars
type values = { [string]: string }

local BOOLS: { [string]: boolean } = table.freeze {
	['true'] = true,
	['1'] = true,
	yes = true,
	['false'] = false,
	['0'] = false,
	no = false,
}

local values: values?
local secrets: { string } = {}

-- .env only; process.env is a lune proxy (not clonable), read() falls back to it
local function get_values(): values
	if values then return values end

	local loaded = {}
	local source = if fs.isFile '.env' then fs.readFile '.env' else ''
	for line in source:gmatch '[^\r\n]+' do
		local key, value = line:match '^%s*([%w_]+)%s*=%s*(.-)%s*$'
		if key and value then loaded[key] = (value:gsub('^["\'](.*)["\']$', '%1')) end
	end

	values = table.freeze(loaded)
	return loaded
end

-- typed reads; no default = required
local function read(name: string): string?
	local value = get_values()[name] or process.env[name]
	return if value and value ~= '' then value else nil
end

local function is_set(name: string): boolean
	return read(name) ~= nil
end

local function missing(name: string): never
	error(`missing env var {name} (set it in .env)`, 3)
end

local function string_var(name: string, default: string?): string
	return read(name) or default or missing(name)
end

local function number_var(name: string, default: number?): number
	local text = read(name)
	if not text then return default or missing(name) end

	return tonumber(text) or error(`env var {name} is not a number: {text}`, 2)
end

local function bool_var(name: string, default: boolean?): boolean
	local text = read(name)
	if not text and default ~= nil then return default end
	if not text then return missing(name) end

	local value = BOOLS[text:lower()]
	return if value ~= nil then value else error(`env var {name} is not a bool (true|false|1|0|yes|no): {text}`, 2)
end

-- secrets
local function secret_string(name: string, default: string?): string
	local value = read(name) or default or missing(name)
	if not table.find(secrets, value) then table.insert(secrets, value) end
	return value
end

local function redact(text: string): string
	for _, secret in secrets do
		text = text:gsub(secret:gsub('%p', '%%%0'), '***')
	end
	return text
end

-- .env writes: replaces the `name=` line or appends one
local function save(name: string, value: string)
	local source = if fs.isFile '.env' then fs.readFile '.env' else ''
	local line = `{name}={value}`
	local updated, count = source:gsub(`%f[^\n%z]%s*{name}%s*=[^\r\n]*`, (line:gsub('%%', '%%%%')))
	if count == 0 then
		updated = source .. (if source == '' or source:sub(-1) == '\n' then '' else '\n') .. line .. '\n'
	end

	fs.writeFile('.env', updated)
	values = nil
end

-- module
return table.freeze {
	is_set = is_set,
	string = string_var,
	number = number_var,
	bool = bool_var,
	secret = table.freeze { string = secret_string },
	redact = redact,
	save = save,
}
