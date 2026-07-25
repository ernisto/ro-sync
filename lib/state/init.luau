local diff = require '@self/diff'

local parser = require '@self/parser'
export type owner = parser.owner
export type file_input = parser.file_input
export type file_lock = parser.file_lock
export type place_file = parser.place_file
export type social_link = parser.social_link
export type manifest = parser.input
export type lock = parser.lock

export type product_data = parser.product_data
export type product_input = parser.product_input
export type product_lock = parser.product_lock

export type place_data = parser.place_data
export type place_input = parser.place_input
export type place_lock = parser.place_lock

export type universe_data = parser.universe_data
export type universe_input = parser.universe_input
export type universe_lock = parser.universe_lock

local encoder = require '@self/encoder'
export type product = encoder.product
export type place = encoder.place
export type universe = encoder.universe
export type resources = encoder.resources

-- constructors
local function create_input(owner: parser.owner): parser.input
	return { owner = owner, products = {}, places = {} }
end
local function create_state(universe_id: number): parser.lock
	return { universe_id = universe_id, products = {}, places = {} }
end

-- module
return table.freeze {
	parse_manifest = parser.parse_manifest,
	parse_lock = parser.parse_lock,

	create_input = create_input,
	create_state = create_state,

	encode_manifest = encoder.encode_manifest,
	encode_lock = encoder.encode_lock,
	build_resources = encoder.build_resources,

	diff_product = diff.diff_product,
	diff_place = diff.diff_place,
	diff_universe = diff.diff_universe,
	mask_product = diff.mask_product,
	mask_place = diff.mask_place,
	mask_universe = diff.mask_universe,
}
