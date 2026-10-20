local sync_logger = require '@lib/sync_logger'

type diff = (any, any) -> { [string]: any }

-- functions
-- moves an orphaned lock entry onto a new manifest key when its cached input matches
local function orphans(inputs: { [string]: any }, locks: { [string]: any }, diff: diff)
	for key, input in inputs do
		if locks[key] or next(diff({}, input)) == nil then continue end
		for old_key, entry in locks do
			if inputs[old_key] or next(diff(entry.input, input)) then continue end
			locks[key], locks[old_key] = entry, nil
			sync_logger.rekeyed(old_key, key)
			break
		end
	end
end

-- untracked manifest key whose fields all match cloud; files ignored since cloud reads carry no hash
local function matching_key(inputs: { [string]: any }, locks: { [string]: any }, read: any, diff: diff): string?
	for key, input in inputs do
		if locks[key] then continue end
		local fields, changes = diff({}, input), diff(read, input)
		fields.icon_file, fields.asset_file, changes.icon_file, changes.asset_file = nil, nil, nil, nil
		if next(fields) and next(changes) == nil then return key end
	end
	return nil
end

-- module
return table.freeze {
	orphans = orphans,
	matching_key = matching_key,
}
