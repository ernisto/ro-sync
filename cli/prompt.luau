local cloud = require '@pkg/ro_cloud'
local state = require '@lib/state'
local stdio = require '@lune/stdio'

-- types
export type creator = {
	user: { id: number, name: string }?,
	group: cloud.dev_group?,
}

-- functions
local function prompt_creator(session: cloud.cookie_session): creator?
	local groups_res = cloud.develop.get_groups(session)
	assert(groups_res.ok, groups_res.message)

	local user_res = cloud.auth.get_user_info(session)
	local user = assert(user_res.ok and user_res.body, user_res.message)

	local groups = groups_res.body.data
	local options = { `@{user.name} ({user.id})` }

	for _, group in groups do
		table.insert(options, `{group.name} ({group.id})`)
	end

	local option = stdio.prompt('select', 'Select a creator', options)
	if not option then return nil end
	if option == 1 then return { user = { id = user.id, name = user.name } } end
	return { group = groups[option - 1] }
end

local function fetch_universes(session: cloud.cookie_session, group: cloud.dev_group?): { cloud.dev_universe }
	local cursor: string? = nil
	local universes: { cloud.dev_universe } = {}

	repeat
		local query = { cursor = cursor }
		local res = if group
			then cloud.develop.get_group_universes(session, { group_id = group.id }, query)
			else cloud.develop.get_user_universes(session, query)

		assert(res.ok, res.message)
		for _, universe in res.body.data :: any do
			table.insert(universes, universe)
		end

		local next_cursor = res.body.nextPageCursor
		cursor = if next_cursor == '' or next_cursor == cursor then nil else next_cursor
	until cursor == nil

	return universes
end

local function prompt_universe(universes: { cloud.dev_universe }): cloud.dev_universe?
	local options = { 'Skip (set universe_id manually later)' }
	for _, universe in universes do
		table.insert(options, `{universe.name} ({universe.id})`)
	end

	local option = stdio.prompt('select', 'Select a universe to import', options)
	return option and option > 1 and universes[option - 1] or nil
end

local function prompt_subject(session: cloud.cookie_session)
	local creator = prompt_creator(session) or error 'creator required'

	local universes = fetch_universes(session, creator.group)
	local universe = prompt_universe(universes)

	local owner: state.owner = if creator.group
		then { group = creator.group.id } :: any
		else { user = (creator.user :: any).id }

	return {
		owner = owner,
		universe = universe,
	}
end

-- module
return table.freeze { prompt_subject = prompt_subject }
