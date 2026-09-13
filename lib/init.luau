return table.freeze {
	state = require '@lib/state',
	sync = require '@lib/sync',
	resources = table.freeze {
		universe = require '@lib/resources/universe',
		product = require '@lib/resources/product',
		place = require '@lib/resources/place',
	},
}
