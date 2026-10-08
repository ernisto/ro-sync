return table.freeze {
	state = require '@lib/state',
	sync = require '@lib/sync',
	resources = table.freeze {
		thumbnail = require '@lib/resources/thumbnail',
		universe = require '@lib/resources/universe',
		product = require '@lib/resources/product',
		place = require '@lib/resources/place',
		pass = require '@lib/resources/pass',
	},
}
