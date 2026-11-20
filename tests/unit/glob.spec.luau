local expect = require '@test/expect'
local glob = require '@utils/glob'

local run = {}

function run.matches_braces_and_double_star()
	local pattern = 'assets/{images,sounds}/**'
	expect.truthy(glob.is_match(pattern, 'assets/images/a.png'))
	expect.truthy(glob.is_match(pattern, 'assets/sounds/x/y/z.ogg'))
	expect.falsy(glob.is_match(pattern, 'assets/models/a.rbxm'))
	expect.falsy(glob.is_match(pattern, 'other/images/a.png'))

	expect.truthy(glob.is_match('img/*.png', 'img/a.png'))
	expect.falsy(glob.is_match('img/*.png', 'img/sub/a.png'))
	expect.truthy(glob.is_match('img/**/*.png', 'img/a.png'))
end

function run.root_stops_at_first_wildcard()
	expect.eq(glob.root_of 'assets/{images,sounds}/**', 'assets')
	expect.eq(glob.root_of 'a/b/*.png', 'a/b')
	expect.eq(glob.root_of '**/*.png', '')
end

return run
