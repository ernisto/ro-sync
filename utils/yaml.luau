local serde = require '@lune/serde'

-- lune's yaml encoder escapes ' as \' inside single-quoted scalars (invalid yaml, must be '').
-- it only inserts \ before ', and emits every quoted scalar alone on its line: `'v'` or `'k':`.
local function encode(value: any): string
	local lines = string.split(serde.encode('yaml', value, true), '\n')
	local block_indent: number? = nil

	for i, line in lines do
		local indent = #(string.match(line, '^ *') :: string)
		if block_indent then
			if line == '' or indent > block_indent then continue end
			block_indent = nil
		end

		if string.match(line, '^ *[|>][-+]?%s*$') then
			block_indent = indent
			continue
		end

		local pad, inner, colon = string.match(line, "^( *)'(.*)'(:?)$")
		if inner then lines[i] = `{pad}'{string.gsub(inner, "\\'", "''")}'{colon}` end
	end
	return table.concat(lines, '\n')
end

return table.freeze { encode = encode }
