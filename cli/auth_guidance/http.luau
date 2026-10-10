local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local http = require '@utils/http'
local c = ctx_log.colors

local apikey = cloud.auth.api_key

-- defs
local CREDENTIALS_URL = 'https://create.roblox.com/dashboard/credentials'

local base_call = http.call
local instrospection_cache: { [string]: cloud.api_key_introspection } = {}

-- helpers
local function missing_scope(endpoint: any, session: cloud.session, path: any): (string?, string?)
	local spec, key = endpoint.auth.apikey, session.api_key_state
	if not spec or not key or next(spec.scope) == nil then return nil, nil end

	local target = if type(path) == 'table' and path.universe_id then tostring(path.universe_id) else nil
	local info = instrospection_cache[key.key] or http.call(apikey.introspect, session, nil, nil)

	for scope in spec.scope do
		if not apikey.has_scope(info, scope, target) then return scope, target end
	end
	return nil, nil
end

local function grant_scopes(endpoint: any, session: cloud.session, path: any)
	local scope, target = missing_scope(endpoint, session, path)
	local warned

	while scope do
		local label = `{scope}{if target then ` ({target})` else ''}`
		if warned ~= label then
			ctx_log.warn(`API Key missing scope {c.bold}{label}`)
			ctx_log.str(`Grant it at {c.green}{CREDENTIALS_URL}{c.reset}, then continue`)
			warned = label
		end
		if not ctx_log.prompt('confirm', 'Granted?') then return end

		local ok, next_scope, next_target = pcall(missing_scope, endpoint, session, path)
		if not ok then
			ctx_log.warn(`Failed to re-check key: {next_scope}`)
			return
		end
		if next_scope ~= scope then ctx_log.str(`{c.green}Scope {c.bold}{label}{c.reset}{c.green} granted`) end
		scope, target = next_scope, next_target
	end
end

-- functions
function call<P, Q, B, R>(endpoint: cloud.endpoint<P, Q, B, R, any>, session: cloud.session, path: P, body: B, query: Q?): R
	grant_scopes(endpoint, session, path)
	local res = base_call(endpoint, session, path, body, query)

	if endpoint == apikey.introspect and session.api_key_state then
		instrospection_cache[session.api_key_state.key] = res :: any
	end
	return res
end

-- module
return table.freeze { call = call }
