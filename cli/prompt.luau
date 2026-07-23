local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local state = require '@lib/state'
local stdio = require '@lune/stdio'
local c = ctx_log.colors

-- defs
local BASEPLATE_PLACE_ID = 95206881

export type creator = { user: nil, group: cloud.dev_group } | { user: { id: number, name: string }, group: nil }

-- helpers
local function fetch_universes(session: cloud.cookie_session, group: cloud.dev_group?): { cloud.dev_universe }
	local universes: { cloud.dev_universe } = {}
	local cursor: string?

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
local function create_universe(session: cloud.cookie_session, creator: creator): cloud.universe_identity?
	local res = cloud.universe.create(session, {
		templatePlaceId = BASEPLATE_PLACE_ID,
		groupId = creator.group and creator.group.id,
	})
	assert(res.ok, res.message)
	return { universe_id = res.body.universeId }
end

-- functions
local function prompt_creator(session: cloud.cookie_session): creator?
	local groups_res = cloud.develop.get_groups(session)
	assert(groups_res.ok, groups_res.message)

	local user_res = cloud.auth.get_user_info(session)
	local user = assert(user_res.ok and user_res.body, user_res.message)

	local groups = groups_res.body.data
	local options = { `@{user.name} {c.dim}({user.id}){c.reset}` }

	for _, group in groups do
		table.insert(options, `{group.name} {c.dim}({group.id}){c.reset}`)
	end

	local option = stdio.prompt('select', 'Select a creator', options)
	if not option then return nil end

	return if option == 1 then { user = { id = user.id, name = user.name } } else { group = groups[option - 1] }
end
local function prompt_universe(
	session: cloud.cookie_session,
	creator: creator,
	universes: { cloud.dev_universe }
): cloud.universe_identity?
	local CREATE = `{c.green}Create a new universe{c.reset}`
	local SKIP = `{c.green}Skip (set universe_id manually later){c.reset}`

	local options = { CREATE, SKIP }
	for _, universe in universes do
		table.insert(options, `{universe.name} {c.dim}({universe.id}){c.reset}`)
	end

	local option = stdio.prompt('select', 'Select a universe to import', options)
	if not option then return nil end

	return if option == 1
		then create_universe(session, creator)
		elseif option == 2 then nil
		else { universe_id = universes[option - 2].id }
end

export type subject = { owner: state.owner, universe: cloud.universe_identity? }
local function prompt_subject(session: cloud.cookie_session): subject
	local creator = prompt_creator(session) or error 'creator required'

	local universes = fetch_universes(session, creator.group)
	local universe = prompt_universe(session, creator, universes)

	local owner = if creator.user then { user = creator.user.id } else { group = assert(creator.group).id }
	return { owner = owner, universe = universe }
end

-- module
return table.freeze { prompt_subject = prompt_subject }
