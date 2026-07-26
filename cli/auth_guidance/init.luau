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
	'universe-places:read',
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
local function print_status(key_info: introspect.introspection?, expected_target: string?): string
	if not key_info then return 'unexisting' end

	local status = if not key_info.enabled then 'disabled' elseif key_info.expired then 'expired' else 'active'
	local color = if status == 'active' then c.green else c.red
	local label = if status == 'active' then 'ENABLED' else string.upper(status)

	local expiry = if key_info.expirationUtcTime then ` {c.dim}(expires {key_info.expirationUtcTime}){c.reset}` else ''
	ctx_log.str(`API Key {color}{key_info.name}{c.reset} {color}{label}{c.reset}{expiry}`)

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
		local suffix = ''
		if targets and #targets > 0 and targets[1] ~= '*' then
			-- hide the target when it's exactly the universe we're going to sync
			local only_expected = #targets == 1 and targets[1] == expected_target
			if not only_expected then suffix = `({table.concat(targets, ',')})` end
		end

		local any_used = false
		for _, op in group.ops do
			if used[`{group.name}:{op}`] then
				any_used = true
				break
			end
		end

		local ops = table.concat(group.ops, '/')
		if any_used then
			table.insert(greens, `{c.green}{group.name}:{ops}{suffix}{c.reset}`)
		else
			-- unused scopes don't need their target shown
			table.insert(grays, `{c.dim}{group.name}:{ops}{c.reset}`)
		end
	end

	-- merge missing operations we rely on by scope name
	local missing, missing_index = {}, {}
	for _, scope in USED_SCOPES do
		if introspect.has_scope(key_info, scope) then continue end
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

	while true do
		local option = ctx_log.prompt('select', 'Authenticate as a Roblox user', labels)
		local kind = if option then options[option].kind else 'ignore'

		if kind == 'local' then
			return cloud.auth.cookie.login(local_cookie :: string)
		elseif kind == 'env' then
			return cloud.auth.cookie.login(COOKIE :: string)
		elseif kind == 'paste' then
			local cookie = ctx_log.prompt('text', 'Paste your .ROBLOSECURITY cookie')
			if cookie ~= '' then return cloud.auth.cookie.login(cookie) end
		elseif kind == 'why' then
			ctx_log.str(
				`Some endpoints {c.dim}(universe/place config, listing & creating universes/places){c.reset} arent`
			)
			ctx_log.str(
				`covered by the Open Cloud API Key, so ro-sync acts {c.bold}as you{c.reset} via a Roblox cookie`
			)
		else
			return nil
		end
	end
end

-- functions

-- ensure the key has `scope` (on `target`), prompting the user to grant it and re-introspecting
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

-- interactive introspection loop; returns the usable session, its key info and the resolved key
local function login(
	api_key: string?,
	expected_target: string?
): (cloud.apikey_session?, introspect.introspection?, string?)
	local session, key_info, key_err
	repeat
		if api_key then
			ctx_log.str(`Introspecting API Key {c.dim}{string.sub(api_key, 1, 8)}...`)
			session = cloud.auth.apikey.login(api_key)
			key_info, key_err = introspect.introspect(session)
		end

		if not api_key then
			ctx_log.warn 'API Key not provided'
		elseif not key_info then
			ctx_log.warn(key_err :: any)
		end

		local status = print_status(key_info, expected_target)
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

-- runs the full auth flow: introspect key, offer to persist it, then authenticate a user
local function authorize(api_key: string?, provided: boolean, expected_target: string?): session?
	local api_session, key_info, resolved = login(api_key, expected_target)
	if not api_session or not key_info or not resolved then return nil end

	-- offer to persist a freshly entered key
	if not provided and confirm_save_api_key() then
		local dotenv = if fs.isFile '.env' then serde.decode('toml', fs.readFile '.env') else {}
		dotenv.API_KEY = resolved
		fs.writeFile('.env', serde.encode('toml', dotenv))
		ctx_log.str(`Saved API Key to {c.bold}.env`)
	end

	local user_session = prompt_user_auth()
	if user_session then
		local me = cloud.auth.get_user_info(user_session)
		if me.ok then
			ctx_log.str(`Authenticated as {c.green}@{me.body.name}{c.reset} {c.dim}({me.body.id})`)
		else
			ctx_log.warn(`Couldnt verify user: {me.message}`)
		end
	end

	return { session = api_session, key_info = key_info, user_session = user_session }
end

-- module
return table.freeze { authorize = authorize, grant_scope = grant_scope }
