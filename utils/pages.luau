-- `fetch_page` yields one page; stops on a nil, empty or repeated next token
local function collect_async<T>(fetch_page: (token: string?) -> ({ T }, string?)): { T }
	local items: { T } = {}
	local token: string? = nil

	repeat
		local page, next_token = fetch_page(token)
		table.move(page, 1, #page, #items + 1, items)

		token = if next_token == '' or next_token == token then nil else next_token
	until token == nil

	return items
end

return table.freeze { collect_async = collect_async }
