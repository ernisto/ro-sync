local fs = require '@lune/fs'
local process = require '@lune/process'

-- ponytail: newest Versions/* install wins; Studio updates wipe it, so restage after one
local function content_dir(): string
	if process.os == 'macos' then return '/Applications/RobloxStudio.app/Contents/Resources/content' end

	local root = `{process.env.LOCALAPPDATA or error 'LOCALAPPDATA not set'}/Roblox/Versions`
	local best, best_time = nil, -math.huge
	local names: { string } = if fs.isDir(root) then fs.readDir(root) else {}
	for _, name in names do
		local dir = `{root}/{name}`
		if not fs.isFile(`{dir}/RobloxStudioBeta.exe`) then continue end

		local modified = fs.metadata(dir).modifiedAt
		local time = if modified then modified.unixTimestamp else 0
		if time > best_time then
			best, best_time = dir, time
		end
	end
	return `{best or error 'Roblox Studio install not found'}/content`
end

return table.freeze { content_dir = content_dir }
