local serde = require '@lune/serde'

-- defs
export type file_input = { hash: string, content: buffer, assetid: nil }
export type file_lock = { hash: string?, content: nil, assetid: number }
export type some_file = file_input | file_lock

-- a content-hashed asset with no roblox assetid (e.g. an uploaded place file)
export type place_file = { hash: string, content: buffer? }

-- main
export type owner = { user: nil, group: number } | { user: number, group: nil }
export type input = {
	owner: owner,
	universe: universe_input?,
	places: { [string]: place_input },
	products: { [string]: product_input },
}
export type lock = {
	universe_id: number?,
	universe: universe_lock?,
	places: { [string]: place_lock },
	products: { [string]: product_lock },
}

-- product
export type product_data = {
	name: string,
	icon_file: file_lock,
	price: number,
	description: string,
	is_for_sale: boolean,
	regional_pricing: boolean,
	store_page_enabled: boolean,
}
export type product_lock = {
	universe_id: number,
	product_id: number,
	input: product_data,
}
export type product_input = {
	name: string,
	icon: string?,
	icon_file: file_input?,
	price: number?,
	description: string?,
	is_for_sale: boolean?,
	regional_pricing: boolean?,
	store_page_enabled: boolean?,

	conflicts: { [string]: any },
	addons: { [string]: any }?,
}

-- place
export type place_data = {
	asset_file: place_file?,
	display_name: string,
	description: string,
	server_size: number,
}
export type place_lock = {
	universe_id: number,
	place_id: number,
	input: place_data,
}
export type place_input = {
	file: string?,
	asset_file: place_file?,
	display_name: string?,
	description: string?,
	server_size: number?,
	conflicts: { [string]: any },
}

-- universe
export type social_link = { title: string?, uri: string? }
export type universe_data = {
	private_server_price: number,
	voice_chat: boolean,

	-- socials
	facebook: social_link,
	twitter: social_link,
	youtube: social_link,
	twitch: social_link,
	discord: social_link,
	roblox_group: social_link,
	guilded: social_link,

	-- devices
	desktop: boolean,
	mobile: boolean,
	tablet: boolean,
	console: boolean,
	vr: boolean,
}
export type universe_lock = {
	universe_id: number,
	input: universe_data,
}
export type universe_input = {
	conflicts: { [string]: any },
	private_server_price: number?,
	voice_chat: boolean?,

	-- socials
	facebook: social_link?,
	twitter: social_link?,
	youtube: social_link?,
	twitch: social_link?,
	discord: social_link?,
	roblox_group: social_link?,
	guilded: social_link?,

	-- devices
	desktop: boolean?,
	mobile: boolean?,
	tablet: boolean?,
	console: boolean?,
	vr: boolean?,
}

local SOCIAL_FIELDS: { string } = { 'facebook', 'twitter', 'youtube', 'twitch', 'discord', 'roblox_group', 'guilded' }
local UNIVERSE_TOGGLES = { 'voice_chat', 'desktop', 'mobile', 'tablet', 'console', 'vr' }

-- helpers
local function check(cond: boolean, msg: string)
	if not cond then error(msg, 0) end
end
local function req(value: any, kind: string, label: string)
	check(type(value) == kind, `{label} must be {kind}, got {type(value)}`)
end
local function opt(value: any, kind: string, label: string)
	check(value == nil or type(value) == kind, `{label} must be {kind} or nil, got {type(value)}`)
end
local function string_map(value: any, label: string): { [string]: any }
	if value == nil then return {} end
	req(value, 'table', label)

	for key, entry in value do
		check(type(key) == 'string', `{label} keys must be strings, got {type(key)}`)
		req(entry, 'table', `{label}.{tostring(key)}`)
	end
	return value
end

-- functions
local function validate_owner(owner: any, label: string)
	req(owner, 'table', label)

	local has_user, has_group = owner.user ~= nil, owner.group ~= nil
	check(has_user ~= has_group, `{label} must set exactly one of user/group`)

	if has_user then req(owner.user, 'number', `{label}.user`) end
	if has_group then req(owner.group, 'number', `{label}.group`) end
end

local function validate_social(link: any, label: string)
	req(link, 'table', label)
	opt(link.title, 'string', `{label}.title`)
	opt(link.uri, 'string', `{label}.uri`)
end

local function validate_product_input(p: any, label: string)
	req(p, 'table', label)
	req(p.name, 'string', `{label}.name`)
	opt(p.icon, 'string', `{label}.icon`)
	opt(p.price, 'number', `{label}.price`)
	opt(p.description, 'string', `{label}.description`)
	opt(p.is_for_sale, 'boolean', `{label}.is_for_sale`)
	opt(p.regional_pricing, 'boolean', `{label}.regional_pricing`)
	opt(p.store_page_enabled, 'boolean', `{label}.store_page_enabled`)
	opt(p.addons, 'table', `{label}.addons`)
	opt(p.conflicts, 'table', `{label}.conflicts`)
	p.conflicts = p.conflicts or {}
end

local function validate_place_input(p: any, label: string)
	req(p, 'table', label)
	opt(p.file, 'string', `{label}.file`)
	opt(p.display_name, 'string', `{label}.display_name`)
	opt(p.description, 'string', `{label}.description`)
	opt(p.server_size, 'number', `{label}.server_size`)
	opt(p.conflicts, 'table', `{label}.conflicts`)
	p.conflicts = p.conflicts or {}
end

local function validate_universe_input(u: any, label: string)
	req(u, 'table', label)

	for _, field in SOCIAL_FIELDS do
		if u[field] ~= nil then validate_social(u[field], `{label}.{field}`) end
	end
	for _, toggle in UNIVERSE_TOGGLES do
		opt(u[toggle], 'boolean', `{label}.{toggle}`)
	end

	opt(u.private_server_price, 'number', `{label}.private_server_price`)
	opt(u.conflicts, 'table', `{label}.conflicts`)
	u.conflicts = u.conflicts or {}
end

-- parsers
local function parse_manifest(content: buffer): input
	local data = serde.decode('yaml', content)
	req(data, 'table', 'manifest')
	check(data.version == 1, `unsupported manifest version {tostring(data.version)}`)
	validate_owner(data.owner, 'manifest.owner')

	data.products = string_map(data.products, 'manifest.products')
	for key, product in data.products do
		validate_product_input(product, `manifest.products.{key}`)
	end

	data.places = string_map(data.places, 'manifest.places')
	for key, place in data.places do
		validate_place_input(place, `manifest.places.{key}`)
	end

	if data.universe ~= nil then validate_universe_input(data.universe, 'manifest.universe') end
	return data
end

local function parse_lock(content: buffer): lock
	local data = serde.decode('yaml', content)
	req(data, 'table', 'lock')
	check(data.version == 1, `unsupported lock version {tostring(data.version)}`)
	opt(data.universe_id, 'number', 'lock.universe_id')

	data.products = string_map(data.products, 'lock.products')
	for key, product in data.products do
		local label = `lock.products.{key}`
		req(product.universe_id, 'number', `{label}.universe_id`)
		req(product.product_id, 'number', `{label}.product_id`)
		validate_product_input(product.input, `{label}.input`)
	end

	data.places = string_map(data.places, 'lock.places')
	for key, place in data.places do
		local label = `lock.places.{key}`
		req(place.universe_id, 'number', `{label}.universe_id`)
		req(place.place_id, 'number', `{label}.place_id`)
		validate_place_input(place.input, `{label}.input`)
	end

	if data.universe ~= nil then
		req(data.universe, 'table', 'lock.universe')
		req(data.universe.universe_id, 'number', 'lock.universe.universe_id')
		validate_universe_input(data.universe.input, 'lock.universe.input')
	end

	return data
end

-- module
return table.freeze {
	SOCIAL_FIELDS = SOCIAL_FIELDS,
	parse_manifest = parse_manifest,
	parse_lock = parse_lock,
}
