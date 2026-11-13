local process = require '@lune/process'

local function open_url(url: string)
	if process.os == 'windows' then
		process.exec('', { `explorer "{url}"` }, { shell = true })
	elseif process.os == 'macos' then
		process.exec('open', { url })
	else
		process.exec('xdg-open', { url })
	end
end

return open_url
