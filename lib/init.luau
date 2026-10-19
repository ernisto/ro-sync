return table.freeze {
	import = require '@lib/import',
	state = require '@lib/state',
	sync = require '@lib/sync',
	resources = table.freeze {
		thumbnail = require '@lib/resources/thumbnail',
		icon = require '@lib/resources/icon',
		universe = require '@lib/resources/universe',
		product = require '@lib/resources/product',
		place = require '@lib/resources/place',
		pass = require '@lib/resources/pass',
	},
}
