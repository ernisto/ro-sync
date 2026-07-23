local expect = require '@test/expect'
local http = require '@utils/http'

local run = {}

-- a rate-limited response must honor Retry-After and retry instead of erroring immediately
function run.respects_retry_after_header()
	local attempts = 0
	local function fn(): any
		attempts += 1
		if attempts == 1 then
			return { ok = false, code = 429, message = 'Too Many Requests', headers = { ['retry-after'] = '0' } }
		end
		return { ok = true, code = 200, body = 'done' }
	end

	local body = http.request('GET', 'places/1', fn)

	expect.eq(body, 'done')
	expect.eq(attempts, 2, 'rate-limited request must retry after honoring Retry-After')
end

-- header lookup is case-insensitive (roblox mixes Retry-After / retry-after casing)
function run.retry_after_is_case_insensitive()
	local attempts = 0
	local function fn(): any
		attempts += 1
		if attempts == 1 then
			return { ok = false, code = 429, message = 'slow down', headers = { ['Retry-After'] = '0' } }
		end
		return { ok = true, code = 200, body = 'ok' }
	end

	expect.eq(http.request('GET', 'places/1', fn), 'ok')
	expect.eq(attempts, 2)
end

-- non-rate-limit failures still error out immediately, without retrying
function run.non_rate_limit_error_does_not_retry()
	local attempts = 0
	local function fn(): any
		attempts += 1
		return { ok = false, code = 404, message = 'not found' }
	end

	local ok, err = pcall(http.request, 'GET', 'places/1', fn)
	expect.falsy(ok, 'a 404 must surface as an error')
	expect.eq(tostring(err), 'not found')
	expect.eq(attempts, 1, 'non-rate-limit failures must not be retried')
end

return run
