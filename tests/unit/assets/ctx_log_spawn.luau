local ctx_log = require '@utils/ctx_log'
local task = require '@lune/task'

local function worker(name: string)
	ctx_log.str(`{name} 1`)
	task.wait(0.01)
	ctx_log.str 'pending'
	ctx_log.clear_line()
	ctx_log.str(`{name} 2`)
end

local join_a = ctx_log.spawn(worker, 'a')
local join_b = ctx_log.spawn(worker, 'b')
local join_err = ctx_log.spawn(error, 'boom')
join_a()
join_b()
join_err()
ctx_log.str 'done'
