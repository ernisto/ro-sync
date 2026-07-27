local task = require '@lune/task'

local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local c = ctx_log.colors

-- defs
local MAX_RETRIES = 5

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
local function request<T>(method: string, path: string, fn: () -> cloud.http_result<T, any>): T
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

-- module
return table.freeze { request = request }
