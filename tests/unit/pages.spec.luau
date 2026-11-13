local expect = require '@test/expect'
local pages = require '@utils/pages'

local run = {}

function run.collects_until_token_runs_out()
	local book: { [string]: { any } } = { [''] = { { 1, 2 }, 'b' }, b = { { 3 }, 'c' }, c = { { 4 }, '' } }

	local items = pages.collect_async(function(token)
		local page = book[token or '']
		return page[1], page[2]
	end)

	expect.eq(table.concat(items, ','), '1,2,3,4')
end

function run.stops_on_repeated_token()
	local calls = 0

	local items = pages.collect_async(function(_token)
		calls += 1
		return { calls }, 'same'
	end)

	expect.eq(calls, 2)
	expect.eq(#items, 2)
end

return run
