local cloud = require '@pkg/ro_cloud'
local http = require '@utils/http'
local tbl = require '@utils/tbl'

local base = require './base'
local product = require './product'
type input_file = base.input_file
type lock_file = base.lock_file
type api_file = base.api_file

-- defs
export type pass_data<F = api_file> = {
	name: string,
	icon_file: F,
	price: number,
	description: string,
	is_for_sale: boolean,
	regional_pricing: boolean,
}
export type pass_input = product.product_input
export type pass_lock = {
	universe_id: number,
	pass_id: number,
	input: pass_data<lock_file>,
}

-- validation
local function validate_input(p: any, label: string)
	product.validate_input(p, label)
	base.check(p.store_page_enabled == nil, `{label}.store_page_enabled is not supported on game passes`)
end

local function validate_lock(entry: any, label: string)
	base.req(entry.universe_id, 'number', `{label}.universe_id`)
	base.req(entry.pass_id, 'number', `{label}.pass_id`)

	validate_input(entry.input, `{label}.input`);
	(entry :: any).input.conflicts = nil
end

-- encoding
local function encode_lock_entry(pass: pass_lock): pass_lock
	local input = pass.input
	local icon_file = if input.icon_file
		then { hash = input.icon_file.hash, assetid = input.icon_file.assetid }
		else nil

	return {
		universe_id = pass.universe_id,
		pass_id = pass.pass_id,
		input = tbl.applied(input, { icon_file = icon_file }),
	}
end

-- api type
export type pass_read = pass_data & { universe_id: number, pass_id: number }

local function from_api_result(data: any, universe_id: number): pass_read
	local price_info = data.priceInformation or {}
	return {
		universe_id = universe_id,
		pass_id = data.gamePassId,
		icon_file = { assetid = data.iconAssetId },
		name = data.name,
		price = price_info.defaultPriceInRobux,
		description = data.description,
		is_for_sale = data.isForSale,
		regional_pricing = table.find(price_info.enabledFeatures or {}, 'RegionalPricing') ~= nil,
	}
end

local function to_api_params(data: pass_input)
	return {
		name = data.name,
		price = data.price,
		description = data.description,
		imageFile = data.icon_file and data.icon_file.content,
		isForSale = data.is_for_sale,
		isRegionalPricingEnabled = data.regional_pricing,
	}
end

local function to_pass_lock(read: pass_read, input: pass_input): pass_lock
	local data: any = tbl.subtraction(read, { universe_id = true, pass_id = true })
	data.icon_file = {
		assetid = read.icon_file and read.icon_file.assetid,
		hash = input.icon_file and input.icon_file.hash,
	}
	return { universe_id = read.universe_id, pass_id = read.pass_id, input = data }
end

-- api impl
type session = base.session
type pass_path = { universe_id: number, pass_id: number }
type universe_path = { universe_id: number }

local function update(session: session, pass: pass_path, patch: pass_input): pass_data
	http.call(cloud.pass.update, session, pass, to_api_params(patch))

	-- PATCH has no body: echo the applied patch
	local confirmed: any = tbl.subtraction(patch, { icon = true, icon_file = true, conflicts = true, addons = true })
	if patch.icon_file then confirmed.icon_file = { hash = patch.icon_file.hash } end

	return confirmed
end

local function create(session: session, game: universe_path, data: pass_input): pass_lock
	local universe = { universe_id = game.universe_id }
	local result =
		from_api_result(http.call(cloud.pass.create, session, universe, to_api_params(data)), game.universe_id)

	return to_pass_lock(result, data)
end

local function get(session: session, pass: pass_path): pass_read
	return from_api_result(http.call(cloud.pass.get, session, pass, nil), pass.universe_id)
end

local function list(session: session, universe: universe_path): { any }
	local passes = {}
	local token: string? = nil
	repeat
		local page = http.call(cloud.pass.list, session, universe, nil, { pageToken = token })

		for _, pass in page.gamePasses do
			table.insert(passes, pass)
		end
		token = if page.nextPageToken and page.nextPageToken ~= '' then page.nextPageToken else nil
	until token == nil

	return passes
end

-- module
return table.freeze {
	validate_input = validate_input,
	validate_lock = validate_lock,

	encode_input = product.encode_input,
	encode_lock_entry = encode_lock_entry,

	diff = product.diff,
	mask = product.mask,

	from_api_result = from_api_result,
	to_api_params = to_api_params,
	to_pass_lock = to_pass_lock,

	create = create,
	get = get,
	update = update,
	list = list,
}
