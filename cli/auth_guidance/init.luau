local args = require '@cli/args'
local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'
local http = require '@utils/http'
local roblox = require '@lune/roblox'
local c = ctx_log.colors

local apikey = cloud.auth.api_key

-- defs
local INTERACTIVE = args.INTERACTIVE
local AUTO_ACCEPT = args.AUTO_ACCEPT

local COOKIE = cli.str 'roblox-cookie' or env.is_set 'ROBLOX_COOKIE' and env.secret.string 'ROBLOX_COOKIE' or nil
if COOKIE and not COOKIE:match '^%.ROBLOSECURITY=' then COOKIE = '.ROBLOSECURITY=' .. COOKIE end

local CREDENTIALS_URL = require('@cli/auth_guidance/http').CREDENTIALS_URL
local USED_SCOPES = {
	'universe:read',
	'universe:write',
	'game-pass:read',
	'game-pass:write',
	'universe.place:write',
	'universe-places:write',
	'developer-product:read',
	'developer-product:write',
}

type key_status = 'missing' | 'disabled' | 'expired' | 'active'
type auth_choice = 'local' | 'env' | 'paste' | 'why' | 'ignore'

export type session = {
	session: cloud.session,
	key_info: cloud.api_key_introspection,
	user_session: cloud.session?,
}

-- helpers
local USED: { [string]: true } = {}
for _, scope in USED_SCOPES do
	USED[scope] = true
end

type scope_group = { name: string, targets: { string }?, ops: { string } }

local function get_key_status(key_info: cloud.api_key_introspection?): key_status
	if not key_info then return 'missing' :: key_status end
	if not key_info.enabled then return 'disabled' :: key_status end
	if key_info.expired then return 'expired' :: key_status end
	return 'active' :: key_status
end

-- groups keep insertion order; `by_key` dedupes them
local function ensure_group(
	groups: { scope_group },
	by_key: { [string]: scope_group },
	key: string,
	name: string,
	targets: { string }?
): scope_group
	local existing = by_key[key]
	if existing then return existing end

	local group: scope_group = { name = name, targets = targets, ops = {} }
	by_key[key] = group
	table.insert(groups, group)
	return group
end

-- operations of scopes sharing the same name+targets, merged in grant order
local function group_granted_scopes(key_info: cloud.api_key_introspection): { scope_group }
	local groups: { scope_group } = {}
	local by_key: { [string]: scope_group } = {}

	for _, scope in key_info.scopes do
		local targets = scope.universeIds or scope.groupIds or scope.userIds
		local key = `{scope.name}|{if targets then table.concat(targets, ',') else ''}`
		local group = ensure_group(groups, by_key, key, scope.name, targets)

		for _, op in scope.operations do
			if not table.find(group.ops, op) then table.insert(group.ops, op) end
		end
	end

	return groups
end

-- operations we rely on but the key lacks, merged by scope name
local function group_missing_scopes(key_info: cloud.api_key_introspection, target: string?): { scope_group }
	local groups: { scope_group } = {}
	local by_name: { [string]: scope_group } = {}

	for _, scope in USED_SCOPES do
		if apikey.has_scope(key_info, scope, target) then continue end

		local name, op = string.match(scope, '^(.*):([^:]+)$')
		local group = ensure_group(groups, by_name, name :: string, name :: string)
		table.insert(group.ops, op :: string)
	end

	return groups
end

local function is_targeting(targets: { string }?, target: string?): boolean
	local is_global = not targets or #targets == 0 or targets[1] == '*'
	return is_global or (target ~= nil and table.find(targets :: { string }, target) ~= nil)
end

local function is_used(group: scope_group): boolean
	for _, op in group.ops do
		if USED[`{group.name}:{op}`] then return true end
	end
	return false
end

-- green: used, yellow: relied on but missing, gray: granted but unused
local function format_scope_labels(key_info: cloud.api_key_introspection, target: string?): { string }
	local greens, grays = {}, {}

	for _, group in group_granted_scopes(key_info) do
		local ops = table.concat(group.ops, '/')
		local used = is_used(group)
		local targeting = is_targeting(group.targets, target)

		if used and targeting then
			table.insert(greens, `{c.green}{group.name}:{ops}{c.reset}`)
		else
			-- only show targets on used scopes granted for a different universe
			local suffix = if used then `({table.concat(group.targets :: { string }, ',')})` else ''
			table.insert(grays, `{c.dim}{group.name}:{ops}{suffix}{c.reset}`)
		end
	end

	local labels = greens
	for _, group in group_missing_scopes(key_info, target) do
		table.insert(labels, `{c.yellow}{group.name}:{table.concat(group.ops, '/')}{c.reset}`)
	end
	table.move(grays, 1, #grays, #labels + 1, labels)

	return labels
end

local function print_status(key_info: cloud.api_key_introspection?, api_key: string?, universe_id: number?): key_status
	local status: key_status = get_key_status(key_info)
	if not key_info then return status end

	local color = if status == 'active' then c.green else c.red
	local prefix = if api_key then ` {c.dim}({string.sub(api_key, 1, 8)}...){c.reset}` else ''
	local expiry = if key_info.expirationUtcTime then ` {c.dim}(expires {key_info.expirationUtcTime}){c.reset}` else ''

	ctx_log.str(`Logged in api key {color}{key_info.name}{prefix} {color}`)
	ctx_log.str(`Currently {c.green}{string.upper(status)}{c.reset}{expiry}`)

	local target = if universe_id then tostring(universe_id) else nil
	local labels = format_scope_labels(key_info, target)
	ctx_log.str(`Scopes: {if #labels > 0 then table.concat(labels, ', ') else 'none'}`)

	return status
end

local function prompt_api_key(): string?
	if not INTERACTIVE then
		ctx_log.print_error 'No usable API Key'
		return nil
	end

	local key = ctx_log.prompt('text', 'Enter a new API Key')
	return if key ~= '' then key else nil
end

local function confirm_save_api_key(): boolean
	if not INTERACTIVE then return false end
	return ctx_log.prompt('confirm', `Save this API Key to {c.green}.env{c.reset}?`)
end

local function describe(cookie: string): string?
	local ok, me = pcall(http.call, cloud.auth.cookie.get_info, cloud.auth.new:cookie(cookie), nil, nil)
	return if ok then `@{me.name}{c.reset} {c.dim}({me.id}){c.reset}` else nil
end

local function prompt_user_auth(): cloud.session?
	if not INTERACTIVE then return COOKIE and cloud.auth.new:cookie(COOKIE) end

	local options: { { label: string, kind: auth_choice } } = {
		{ label = 'Enter a .ROBLOSECURITY cookie', kind = 'paste' },
		{ label = `{c.dim}Why authenticate?{c.reset}`, kind = 'why' },
		{ label = `{c.dim}Ignore{c.reset}`, kind = 'ignore' },
	}

	local ok, local_cookie = pcall(roblox.getAuthCookie)
	if ok and local_cookie then
		local local_who = describe(local_cookie)
		table.insert(options, 1, { label = `{c.green}Log in as {local_who}`, kind = 'local' :: auth_choice })
	end
	if COOKIE then
		local env_who = describe(COOKIE)
		local env_label = if env_who
			then `{c.green}Log in from ROBLOX_COOKIE as {env_who}`
			else `{c.green}Log in from ROBLOX_COOKIE{c.reset}`
		table.insert(options, 1, { label = env_label, kind = 'env' :: auth_choice })
	end

	if AUTO_ACCEPT then
		local cookie = COOKIE or local_cookie
		return cookie and cloud.auth.new:cookie(cookie)
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
			return cloud.auth.new:cookie(local_cookie :: string)
		elseif kind == 'env' then
			return cloud.auth.new:cookie(COOKIE :: string)
		elseif kind == 'paste' then
			local cookie = ctx_log.prompt('text', 'Paste your .ROBLOSECURITY cookie')
			if cookie ~= '' then return cloud.auth.new:cookie(cookie) end
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
local function prompt_valid_api_key(
	api_key: string?,
	universe_id: number?
): (cloud.session?, cloud.api_key_introspection?, string?)
	local session, key_info, key_err
	repeat
		if api_key then
			session = cloud.auth.new:api_key(api_key)
			local ok, res = pcall(http.call, apikey.introspect, session, nil, nil)
			key_info, key_err = if ok then res else nil, if ok then nil else res
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

local function authenticate_user(): cloud.session?
	local user_session = prompt_user_auth()
	if user_session then
		local ok, me = pcall(http.call, cloud.auth.cookie.get_info, user_session, nil, nil)
		if ok then
			ctx_log.str(`Authenticated as {c.green}@{me.name} {c.dim}({me.id})`)
		else
			ctx_log.warn(`Couldnt authenticate, {me}`)
		end
	end
	return user_session
end

local function authenticate_key(
	api_key: string?,
	provided: boolean,
	universe_id: number?
): (cloud.session?, cloud.api_key_introspection?)
	local api_session, key_info, resolved = prompt_valid_api_key(api_key, universe_id)
	if not api_session or not key_info or not resolved then return nil end

	if not provided and confirm_save_api_key() then
		env.save('API_KEY', resolved)
		ctx_log.str(`Saved API Key to {c.bold}.env`)
	end

	return api_session, key_info
end

-- module
return table.freeze {
	authenticate_user = authenticate_user,
	authenticate_key = authenticate_key,
}
