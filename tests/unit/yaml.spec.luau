local expect = require '@test/expect'
local serde = require '@lune/serde'
local yaml = require '@utils/yaml'

-- tests
local run = {}

function run.should_round_trip_single_quotes()
	local value: any = {
		["it's"] = "Dev's 'Pack'",
		path = 'C:\\p\\',
		mixed = "a\\'b",
		block = "l1 'q'\n'l2'",
		list = { "x'", { k = "y':" } :: any },
	}
	local back = serde.decode('yaml', yaml.encode(value))
	expect.eq(back["it's"], value["it's"])
	expect.eq(back.path, value.path)
	expect.eq(back.mixed, value.mixed)
	expect.eq(back.block, value.block)
	expect.eq(back.list[1], "x'")
	expect.eq(back.list[2].k, "y':")
end

return run
