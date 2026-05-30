local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local c = ctx_log.colors

-- functions
local function log_http_result(method: string, url: string, ok: boolean, code: number?, err_msg: string?)
	local status
	if ok then
		status = `{c.green}OK {code or 200}`
	else
		local code_str = if code then tostring(code) else '???'
		local detail = if err_msg then `: {err_msg}` else ''
		status = `{c.red}FAIL {code_str}{detail}`
	end
	ctx_log.str(`{c.dim}({method}) {url}{c.reset} {status}`)
end
local function log_http_call<T>(method: string, path: string, fn: () -> cloud.http_result<T, any>): T
	local response = fn()
	if response.ok then
		log_http_result(method, path, true, 200)
		return response.body
	end

	log_http_result(method, path, false, response.code, response.message)
	error(response.message, 0)
end

-- module
return table.freeze { log_http_call = log_http_call }
