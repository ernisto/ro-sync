local cli = require '@utils/cli'
local cloud = require '@pkg/ro_cloud'
local ctx_log = require '@utils/ctx_log'
local env = require '@utils/env'
local state = require '@lib/state'
local c = ctx_log.colors

-- defs
local BASEPLATE_PLACE_ID = 95206881
local AUTO_ACCEPT = cli.bool 'yes' or cli.bool 'y'
local INTERACTIVE_MODE = not env.str 'CI'

type creator = { user: nil, group: cloud.dev_group } | { user: { id: number, name: string }, group: nil }

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
local function create_universe(session: cloud.cookie_session, creator: creator): cloud.universe_identity
	local res = cloud.universe.create(session, {
		templatePlaceId = BASEPLATE_PLACE_ID,
		groupId = creator.group and creator.group.id,
	})
	assert(res.ok, res.message)
	return { universe_id = res.body.universeId }
end

-- functions
local function prompt_creator(session: cloud.cookie_session): creator?
	assert(INTERACTIVE_MODE, 'not possible to choice a subject')

	local groups_res = cloud.develop.get_groups(session)
	assert(groups_res.ok, groups_res.message)

	local user_res = cloud.auth.get_user_info(session)
	local user = assert(user_res.ok and user_res.body, user_res.message)

	local groups = groups_res.body.data
	local options = { `@{user.name} {c.dim}({user.id}){c.reset}` }

	for _, group in groups do
		table.insert(options, `{group.name} {c.dim}({group.id}){c.reset}`)
	end

	local option = ctx_log.prompt('select', 'Browse games of creator', options)
	if not option then return nil end
	ctx_log.str(`Browsing games of {c.green}{options[option]}`)

	return if option == 1 then { user = { id = user.id, name = user.name } } else { group = groups[option - 1] }
end
local function prompt_universe(
	session: cloud.cookie_session,
	creator: creator,
	universes: { cloud.dev_universe }
): cloud.universe_identity
	assert(INTERACTIVE_MODE, 'not possible to choice a subject')

	local options = { `{c.green}Create a new universe{c.reset}` }
	for _, universe in universes do
		table.insert(options, `{universe.name} {c.dim}({universe.id}){c.reset}`)
	end

	local option = ctx_log.prompt('select', 'Select the universe', options) or error 'universe required'
	if option == 1 then
		ctx_log.str(`Creating a {c.green}New universe`)
		return create_universe(session, creator)
	end
	return { universe_id = universes[option - 1].id }
end

export type subject = { owner: state.owner, universe: cloud.universe_identity }
local function prompt_subject(session: cloud.cookie_session): subject
	assert(INTERACTIVE_MODE, 'not possible to choice a subject')
	local creator = prompt_creator(session) or error 'creator required'

	local universes = fetch_universes(session, creator.group)
	local universe = prompt_universe(session, creator, universes)
	ctx_log.clear_line()

	local owner = if creator.user then { user = creator.user.id } else { group = assert(creator.group).id }
	return { owner = owner, universe = universe }
end

local function confirm_reimport(inputs_path: string): boolean
	if not INTERACTIVE_MODE then return false end
	local msg =
		`Enable {c.green}--scan-state{c.reset}? {c.dim}it scan the whole roblox cloud state and reconciles with {inputs_path}`
	local ok = ctx_log.prompt('confirm', msg)
	ctx_log.str(if ok then `Enabled {c.green}--scan-state` else `{c.dim}Skipping cloud scan`)
	return ok
end

local function confirm_regen_input(input_path: string, state_path: string): boolean
	if AUTO_ACCEPT then return true end

	if env.str 'CI' then
		ctx_log.warn(`Running on CI, skipping input regeneration`)
		return false
	else
		local msg = `No {c.bold}{input_path}{c.reset} found, regenerate it from {c.bold}{state_path}{c.reset}?`
		local ok = ctx_log.prompt('confirm', msg)
		ctx_log.str(if ok then `Regenerating {c.green}{input_path}` else `{c.dim}Keeping empty manifest`)
		return ok
	end
end

local function prompt_add_overwrite(): boolean
	if AUTO_ACCEPT then return true end
	if not INTERACTIVE_MODE then return false end

	local msg =
		`Enable {c.green}--overwrite{c.reset}? {c.dim}We already pulled all changes made externally, push now means overwrite those external changes`
	local ok = ctx_log.prompt('confirm', msg)
	ctx_log.str(if ok then `Overwriting with local changes` else `{c.dim}Taking a time to analyze external changes`)
	return ok
end

-- module
return table.freeze {
	prompt_subject = prompt_subject,
	confirm_reimport = confirm_reimport,
	confirm_regen_input = confirm_regen_input,
	prompt_add_overwrite = prompt_add_overwrite,
}
