local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'
local fs = require '@lune/fs'
local roblox = require '@lune/roblox'
local serde = require '@lune/serde'
local c = ctx_log.colors

local introspect = require '@self/introspect'

-- defs
local CREDENTIALS_URL = 'https://create.roblox.com/dashboard/credentials'
local INTERACTIVE_MODE = not env.str 'CI'
local AUTO_ACCEPT = cli.bool 'yes' or cli.bool 'y'
local COOKIE = env.str 'ROBLOX_COOKIE'

-- scopes ro-sync relies on, used to color the introspected key status
local USED_SCOPES = {
	'universe:read',
	'universe:write',
	'universe-places:write',
	'developer-product:read',
	'developer-product:write',
}

export type session = {
	session: cloud.apikey_session,
	key_info: introspect.introspection,
	user_session: cloud.cookie_session?,
}

-- helpers
local function print_status(key_info: introspect.introspection?, api_key: string?, universe_id: number?): string
	if not key_info then return 'unexisting' end

	local status = if not key_info.enabled then 'disabled' elseif key_info.expired then 'expired' else 'active'
	local color = if status == 'active' then c.green else c.red

	local prefix = if api_key then ` {c.dim}({string.sub(api_key, 1, 8)}...){c.reset}` else ''
	local expiry = if key_info.expirationUtcTime then ` {c.dim}(expires {key_info.expirationUtcTime}){c.reset}` else ''

	ctx_log.str(`Logged in api key {color}{key_info.name}{prefix} {color}`)
	ctx_log.str(`Currently {c.green}{string.upper(status)}{c.reset}{expiry}`)

	local used = {}
	for _, scope in USED_SCOPES do
		used[scope] = true
	end

	-- merge operations of scopes sharing the same name+target
	local groups, index = {}, {}
	for _, scope in key_info.scopes do
		local targets = scope.universeIds or scope.groupIds or scope.userIds
		local key = `{scope.name}|{if targets then table.concat(targets, ',') else ''}`

		local group = index[key]
		if not group then
			group = { name = scope.name, targets = targets, ops = {}, seen = {} }
			index[key] = group
			table.insert(groups, group)
		end
		for _, op in scope.operations do
			if not group.seen[op] then
				group.seen[op] = true
				table.insert(group.ops, op)
			end
		end
	end

	-- green: used, yellow: relied on but missing, gray: granted but unused
	local greens, grays = {}, {}
	for _, group in groups do
		local targets = group.targets

		-- a scope only helps if it targets our universe (or everything)
		local applies = not targets or #targets == 0 or targets[1] == '*'
		if targets and #targets > 0 and targets[1] ~= '*' then
			for _, target in targets do
				if target == tostring(universe_id) then applies = true end
			end
		end

		local any_used = false
		for _, op in group.ops do
			if used[`{group.name}:{op}`] then
				any_used = true
				break
			end
		end

		-- only show the target on used scopes granted for a different universe
		local suffix = if any_used and not applies then `({table.concat(targets, ',')})` else ''

		local ops = table.concat(group.ops, '/')
		if any_used and applies then
			table.insert(greens, `{c.green}{group.name}:{ops}{c.reset}`)
		else
			table.insert(grays, `{c.dim}{group.name}:{ops}{suffix}{c.reset}`)
		end
	end

	-- merge missing operations we rely on by scope name
	local missing, missing_index = {}, {}
	local target = if universe_id then tostring(universe_id) else nil
	for _, scope in USED_SCOPES do
		if introspect.has_scope(key_info, scope, target) then continue end
		local name, op = string.match(scope, '^(.*):([^:]+)$')

		local group = missing_index[name]
		if not group then
			group = { name = name, ops = {} }
			missing_index[name] = group
			table.insert(missing, group)
		end
		table.insert(group.ops, op)
	end

	local yellows = {}
	for _, group in missing do
		table.insert(yellows, `{c.yellow}{group.name}:{table.concat(group.ops, '/')}{c.reset}`)
	end

	local labels = {}
	table.move(greens, 1, #greens, 1, labels)
	table.move(yellows, 1, #yellows, #labels + 1, labels)
	table.move(grays, 1, #grays, #labels + 1, labels)
	ctx_log.str(`Scopes: {if #labels > 0 then table.concat(labels, ', ') else 'none'}`)

	return status
end

local function prompt_api_key(): string?
	if not INTERACTIVE_MODE then
		ctx_log.error 'No usable API Key'
		return nil
	end

	local key = ctx_log.prompt('text', 'Enter a new API Key')
	return if key ~= '' then key else nil
end

local function confirm_save_api_key(): boolean
	if not INTERACTIVE_MODE then return false end
	return ctx_log.prompt('confirm', `Save this API Key to {c.green}.env{c.reset}?`)
end

local function describe(cookie: string): string?
	local me = cloud.auth.get_user_info(cloud.auth.cookie.login(cookie))
	return if me.ok then `@{me.body.name}{c.reset} {c.dim}({me.body.id}){c.reset}` else nil
end

local function prompt_user_auth(): cloud.cookie_session?
	if AUTO_ACCEPT then return COOKIE and cloud.auth.cookie.login(COOKIE) end
	if not INTERACTIVE_MODE then return nil end

	local options: { { label: string, kind: string } } = {
		{ label = 'Enter a .ROBLOSECURITY cookie', kind = 'paste' },
		{ label = `{c.dim}Why authenticate?{c.reset}`, kind = 'why' },
		{ label = `{c.dim}Ignore{c.reset}`, kind = 'ignore' },
	}

	local ok, local_cookie = pcall(roblox.getAuthCookie)
	if ok and local_cookie then
		local local_who = describe(local_cookie)
		table.insert(options, 1, { label = `{c.green}Log in as {local_who}`, kind = 'local' })
	end
	if COOKIE then
		local env_who = describe(COOKIE)
		local env_label = if env_who
			then `{c.green}Log in from ROBLOX_COOKIE as {env_who}`
			else `{c.green}Log in from ROBLOX_COOKIE{c.reset}`
		table.insert(options, 1, { label = env_label, kind = 'env' })
	end

	local labels = {}
	for _, option in options do
		table.insert(labels, option.label)
	end

	local replied_why = false
	while true do
		local option = ctx_log.prompt('select', 'Authenticate as a Roblox user', labels)
		local kind = if option then options[option].kind else 'ignore'

		if replied_why then
			ctx_log.clear_line()
			ctx_log.clear_line()
		end

		if kind == 'local' then
			return cloud.auth.cookie.login(local_cookie :: string)
		elseif kind == 'env' then
			return cloud.auth.cookie.login(COOKIE :: string)
		elseif kind == 'paste' then
			local cookie = ctx_log.prompt('text', 'Paste your .ROBLOSECURITY cookie')
			if cookie ~= '' then return cloud.auth.cookie.login(cookie) end
		elseif kind == 'why' then
			ctx_log.str(`{c.dim}Endpoints for universe config and place config, arent covered by the Open Cloud API`)
			ctx_log.str(`{c.dim}So ro-sync acts {c.green}as you{c.reset}{c.dim} via a Roblox cookie`)
			replied_why = true
		else
			return nil
		end
	end
end

-- functions
local function grant_scope(
	session: cloud.apikey_session,
	info: introspect.introspection,
	scope: string,
	target: string?
): introspect.introspection
	if introspect.has_scope(info, scope, target) then return info end
	local label = if target then `({target})` else ''

	if not INTERACTIVE_MODE then
		ctx_log.warn(`API Key missing scope {c.bold}{scope}{label}`)
		return info
	end

	ctx_log.warn(`API Key missing scope {c.bold}{scope}{label}`)
	ctx_log.str(`Grant it at {c.green}{CREDENTIALS_URL}{c.reset}, then continue`)

	repeat
		if not ctx_log.prompt('confirm', 'Granted?') then return info end

		local next_info, err = introspect.introspect(session)
		if not next_info then
			ctx_log.warn(`Failed to re-check key: {err}`)
			return info
		end
		info = next_info
	until introspect.has_scope(info, scope, target)

	ctx_log.str(`{c.green}Scope {c.bold}{label}{c.reset}{c.green} granted`)
	return info
end

local function prompt_valid_api_key(
	api_key: string?,
	universe_id: number?
): (cloud.apikey_session?, introspect.introspection?, string?)
	local session, key_info, key_err
	repeat
		if api_key then
			session = cloud.auth.apikey.login(api_key)
			key_info, key_err = introspect.introspect(session)
		end

		if not api_key then
			ctx_log.warn 'API Key not provided'
		elseif not key_info then
			ctx_log.warn(key_err :: any)
		end

		local status = print_status(key_info, api_key, universe_id)
		if status == 'active' then break end

		if api_key then
			ctx_log.str(`Manage it at {c.green}{CREDENTIALS_URL}`)
		else
			ctx_log.str(`Create one at {c.green}{CREDENTIALS_URL}`)
		end

		local new_key = prompt_api_key()
		if not new_key then return nil end
		api_key = new_key
	until false

	return session, key_info, api_key
end

local function authenticate_user(): cloud.cookie_session?
	local user_session = prompt_user_auth()
	if user_session then
		local me = cloud.auth.get_user_info(user_session)
		if me.ok then
			ctx_log.str(`Authenticated as {c.green}@{me.body.name} {c.dim}({me.body.id})`)
		else
			ctx_log.warn(`Couldnt authenticate, {me.message}`)
		end
	end
	return user_session
end

local function authenticate_key(
	api_key: string?,
	provided: boolean,
	universe_id: number?
): (cloud.apikey_session?, introspect.introspection?)
	local api_session, key_info, resolved = prompt_valid_api_key(api_key, universe_id)
	if not api_session or not key_info or not resolved then return nil end

	if not provided and confirm_save_api_key() then
		local dotenv = if fs.isFile '.env' then serde.decode('toml', fs.readFile '.env') else {}
		dotenv.API_KEY = resolved
		fs.writeFile('.env', serde.encode('toml', dotenv))
		ctx_log.str(`Saved API Key to {c.bold}.env`)
	end

	return api_session, key_info
end

-- module
return table.freeze {
	authenticate_user = authenticate_user,
	authenticate_key = authenticate_key,
	grant_scope = grant_scope,
}
