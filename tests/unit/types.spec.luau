local expect = require '@test/expect'
local sm = require '@test/sync_mock'
local types = require '@lib/types'

local HASH = string.rep('a', 64)
local function icon(hash: string): any
	return { hash = hash, content = buffer.create(0) }
end

-- to_product_lock is the create-result normalization that moved out of sync into the adapter layer
local run = {}

function run.splits_identity_out_of_input()
	local lock = types.to_product_lock(sm.make_product_read { name = 'Pack' }, { name = 'Pack', conflicts = {} } :: any)

	expect.eq(lock.universe_id, sm.UNIVERSE_ID)
	expect.eq(lock.product_id, sm.PRODUCT_ID)
	expect.falsy((lock.input :: any).universe_id, 'identity must not leak into input')
	expect.falsy((lock.input :: any).product_id, 'identity must not leak into input')
	expect.eq(lock.input.name, 'Pack')
end

function run.icon_keeps_cloud_assetid_and_local_hash()
	local read = sm.make_product_read { icon_file = { assetid = sm.ICON_ID }, name = 'Pack' }
	local lock = types.to_product_lock(read, { name = 'Pack', icon_file = icon(HASH), conflicts = {} } :: any)

	expect.eq(lock.input.icon_file.assetid, sm.ICON_ID) -- assetid comes from the cloud result
	expect.eq(lock.input.icon_file.hash, HASH) -- hash comes from the local file we uploaded
end

function run.icon_hash_preserved_when_result_has_no_icon()
	local lock = types.to_product_lock(
		sm.make_product_read { name = 'Pack' },
		{ name = 'Pack', icon_file = icon(HASH), conflicts = {} } :: any
	)

	expect.eq(lock.input.icon_file.hash, HASH)
	expect.falsy(lock.input.icon_file.assetid, 'no cloud assetid when the result had none')
end

return run
