local cloud = require '@pkg/ro_cloud'

-- defs
export type scope = {
	name: string,
	operations: { string },
	universeIds: { string }?,
	userIds: { string }?,
	groupIds: { string }?,
}
export type introspection = {
	name: string,
	authorizedUserId: string?,
	scopes: { scope },
	enabled: boolean,
	expired: boolean,
	expirationUtcTime: string?,
}

local INTROSPECT_URL = 'https://apis.roblox.com/api-keys/v1/introspect'

-- functions
local function introspect(session: cloud.apikey_session): (introspection?, string?)
	local res = cloud.auth.request_json(session, 'POST', INTROSPECT_URL, nil, { apiKey = session.api_key })
	if not res.ok then return nil, res.body.message end
	return res.body :: introspection
end

local function usable(info: introspection): boolean
	return info.enabled and not info.expired
end

-- `scope` is `name:operation` (e.g. `universe.place:read`); `target` is an
-- optional resource id (e.g. a universe id) the scope must be granted on
local function has_scope(info: introspection, scope: string, target: string?): boolean
	local name, operation = string.match(scope, '^(.*):([^:]+)$')
	if not name then error(`malformed scope "{scope}"`) end

	for _, granted in info.scopes do
		if granted.name ~= name then continue end

		local has_op = false
		for _, op in granted.operations do
			if op == operation or op == '*' then
				has_op = true
				break
			end
		end
		if not has_op then continue end

		if not target then return true end
		for _, ids in { granted.universeIds, granted.userIds, granted.groupIds } do
			if not ids then continue end
			for _, id in ids do
				if id == target or id == '*' then return true end
			end
		end
	end
	return false
end

-- module
return table.freeze {
	introspect = introspect,
	usable = usable,
	has_scope = has_scope,
}
