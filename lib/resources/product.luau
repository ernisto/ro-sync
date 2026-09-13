local cloud = require '@pkg/ro_cloud'
local http = require '@utils/http'
local tbl = require '@utils/tbl'

local base = require './base'
type input_file = base.input_file
type lock_file = base.lock_file
type api_file = base.api_file

-- defs
export type product_data<F = api_file> = {
	name: string,
	icon_file: F,
	price: number,
	description: string,
	is_for_sale: boolean,
	regional_pricing: boolean,
	store_page_enabled: boolean,
}
export type product_input = {
	name: string,
	icon: string?,
	icon_file: input_file?,
	price: number?,
	description: string?,
	is_for_sale: boolean?,
	regional_pricing: boolean?,
	store_page_enabled: boolean?,

	conflicts: { [string]: any },
	addons: { [string]: any }?,
}
export type product_lock = {
	universe_id: number,
	product_id: number,
	input: product_data<lock_file>,
}

-- validation
local function validate_input(p: any, label: string)
	base.req(p, 'table', label)
	base.req(p.name, 'string', `{label}.name`)
	base.opt(p.icon, 'string', `{label}.icon`)
	base.opt(p.price, 'number', `{label}.price`)
	base.opt(p.description, 'string', `{label}.description`)
	base.opt(p.is_for_sale, 'boolean', `{label}.is_for_sale`)
	base.opt(p.regional_pricing, 'boolean', `{label}.regional_pricing`)
	base.opt(p.store_page_enabled, 'boolean', `{label}.store_page_enabled`)

	base.opt(p.addons, 'table', `{label}.addons`)
	base.opt(p.conflicts, 'table', `{label}.conflicts`)
	p.conflicts = p.conflicts or {}
end

local function validate_lock(entry: any, label: string)
	base.req(entry.universe_id, 'number', `{label}.universe_id`)
	base.req(entry.product_id, 'number', `{label}.product_id`)

	validate_input(entry.input, `{label}.input`);
	(entry :: any).input.conflicts = nil
end

-- encoding
local function encode_input(product: product_input): product_input
	return tbl.subtraction(product, {
		icon_file = true,
		conflicts = next(product.conflicts) == nil or nil,
		addons = product.addons and next(product.addons) == nil or nil,
	})
end

local function encode_lock_entry(product: product_lock): product_lock
	local input = product.input
	local icon_file = if input.icon_file
		then { hash = input.icon_file.hash, assetid = input.icon_file.assetid }
		else nil

	return {
		universe_id = product.universe_id,
		product_id = product.product_id,
		input = tbl.applied(input, { icon_file = icon_file }),
	}
end

-- diff
local function diff(from: { [string]: any }, to: { [string]: any }): { [string]: any }
	local out = base.diff_fields(from, to, {
		'name',
		'price',
		'description',
		'is_for_sale',
		'regional_pricing',
		'store_page_enabled',
	})

	out.icon_file = base.diff_file(from.icon_file, to.icon_file)
	return out
end

local function mask(read: product_data, input: product_input): product_input
	local out: any = diff(read, input)
	out.conflicts = input.conflicts or {}

	if input.icon ~= nil then out.icon = input.icon end
	if input.addons ~= nil then out.addons = input.addons end
	return out
end

-- api type
export type product_read = product_data & { universe_id: number, product_id: number }

local function from_api_result(data: cloud.product): product_read
	local price_info = data.priceInformation
	return {
		universe_id = data.universeId,
		product_id = data.productId,
		icon_file = { assetid = data.iconImageAssetId },
		name = data.name,
		price = price_info.defaultPriceInRobux,
		description = data.description,
		is_for_sale = data.isForSale,
		store_page_enabled = data.storePageEnabled,
		regional_pricing = table.find(price_info.enabledFeatures, 'RegionalPricing') ~= nil,
	}
end

local function to_api_params(data: product_input)
	return {
		name = data.name,
		price = data.price,
		description = data.description,
		imageFile = data.icon_file and data.icon_file.content,
		isForSale = data.is_for_sale,
		isRegionalPricingEnabled = data.regional_pricing,
		storePageEnabled = data.store_page_enabled,
	}
end

local function to_product_lock(read: product_read, input: product_input): product_lock
	local data: any = {
		name = read.name,
		icon_file = {
			assetid = read.icon_file and read.icon_file.assetid,
			hash = input.icon_file and input.icon_file.hash,
		},
		price = read.price,
		description = read.description,
		is_for_sale = read.is_for_sale,
		regional_pricing = read.regional_pricing,
		store_page_enabled = read.store_page_enabled,
	}

	return { universe_id = read.universe_id, product_id = read.product_id, input = data }
end

-- api impl
local function build_product_api(session: cloud.apikey_session)
	local function update(product: cloud.product_identity, patch: product_input)
		local path = `developer-product/{product.product_id}`
		http.request('PATCH', path, function()
			return cloud.product.update(session, product, to_api_params(patch))
		end)
	end
	local function create(opts, data: product_input): product_lock
		local path = `universes/{opts.universe_id}/developer-products`
		local result = from_api_result(http.request('POST', path, function()
			return cloud.product.create(session, { universe_id = opts.universe_id }, to_api_params(data))
		end))

		return to_product_lock(result, data)
	end
	local function get(product: cloud.product_identity): product_read
		local path = `developer-product/{product.product_id}`
		return from_api_result(http.request('GET', path, function()
			return cloud.product.get(session, product)
		end))
	end
	local function list(universe_id: number)
		local products = {}
		local token: string? = nil
		repeat
			local page = http.request('GET', `universes/{universe_id}/developer-products/creator`, function()
				return cloud.product.list(session, { universe_id = universe_id }, { pageToken = token })
			end)

			for _, product in page.developerProducts do
				table.insert(products, product)
			end
			token = if page.nextPageToken ~= '' then page.nextPageToken else nil
		until token == nil

		return products
	end
	return { get = get, create = create, update = update, list = list }
end

export type api = typeof(build_product_api(_G))

-- module
return table.freeze {
	validate_input = validate_input,
	validate_lock = validate_lock,

	encode_input = encode_input,
	encode_lock_entry = encode_lock_entry,

	diff = diff,
	mask = mask,

	from_api_result = from_api_result,
	to_api_params = to_api_params,
	to_product_lock = to_product_lock,
	build_product_api = build_product_api,
}
