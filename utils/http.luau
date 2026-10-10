local net = require '@lune/net'
local serde = require '@lune/serde'
local task = require '@lune/task'

local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local c = ctx_log.colors

-- defs
local MAX_RETRIES = 5

export type result<T> = { ok: boolean, code: number?, message: string?, headers: any, body: T }

-- functions
local function caseless_header(headers: any, name: string): string?
	if type(headers) ~= 'table' then return nil end
	local lower = name:lower()
	for key, value in headers do
		if type(key) == 'string' and key:lower() == lower then return value end
	end
	return nil
end

local function retry_after(response: any): number?
	if response.code ~= 429 and response.code ~= 503 then return nil end

	local seconds = caseless_header(response.headers, 'retry-after')
	if seconds then return tonumber(seconds) or 0 end

	if caseless_header(response.headers, 'x-ratelimit-remaining') == '0' then
		return tonumber(caseless_header(response.headers, 'x-ratelimit-reset')) or 1
	end
	return nil
end

local function log_http_result(method: string, url: string, ok: boolean?, code: number?, err_msg: string?)
	local status = ''
	if ok == true then
		status = `{c.green}OK {code or 200}`
	elseif ok == false then
		local code_str = if code then tostring(code) else '???'
		local detail = if err_msg then `: {err_msg}` else ''
		status = `{c.red}FAIL {code_str}{detail}`
	end
	ctx_log.str(`{c.dim}({method}) {url}{c.reset} {status}`)
end
local function request<T>(method: string, path: string, fn: () -> result<T>): T
	for attempt = 0, MAX_RETRIES do
		log_http_result(method, path)
		local response = fn()

		ctx_log.clear_line()
		log_http_result(method, path, response.ok, response.code, response.message)

		if response.ok then
			ctx_log.clear_line()
			return response.body
		end

		local interval = if attempt < MAX_RETRIES then retry_after(response) else nil
		if interval == nil then error(response.message, 0) end

		log_http_result(method, path, false, response.code, `rate limited, retrying in {interval}s`)
		task.wait(interval)
	end

	error('exhausted rate-limit retries', 0)
end

local function decode(body: string): any
	if body == '' then return nil end
	local ok, value = pcall(serde.decode, 'json' :: 'json', body)
	return if ok then value else body
end

local function error_message(res: net.FetchResponse, body: any): string
	if type(body) == 'table' then
		local first = body.errors and body.errors[1]
		local message = body.message or (first and first.message)
		if message then return `{res.statusCode} {message}` end
	end
	return `{res.statusCode} {res.statusMessage}`
end

local function send(build: () -> cloud.request, session: cloud.session): result<any>
	local function fetch()
		local req = build()
		return net.request { url = req.url, method = req.method, headers = req.headers, body = req.body }
	end

	local res = fetch()

	-- cookie endpoints reject the first write with a fresh csrf token to retry with
	local csrf = caseless_header(res.headers, 'x-csrf-token')
	if res.statusCode == 403 and csrf and session.cookie_state then
		session.cookie_state.csrf_token = csrf
		res = fetch()
	end

	local body = decode(res.body)
	return {
		ok = res.ok,
		code = res.statusCode,
		message = if res.ok then nil else error_message(res, body),
		headers = res.headers,
		body = body,
	}
end

local module = {}
module.request = request

function module.call<P, Q, B, R>(endpoint: cloud.endpoint<P, Q, B, R, any>, session: cloud.session, path: P, body: B, query: Q?): R
	local function build()
		return endpoint:request(session, path, body, query)
	end
	local label = string.match(build().url, '^https?://([^?]*)') or endpoint.base

	return module.request(endpoint.method, label, function()
		return send(build, session)
	end)
end

return module -- not frozen: specs stub `request`, cli wraps `call`
