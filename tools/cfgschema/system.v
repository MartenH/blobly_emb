module cfgschema

import comm.doip

// system: system.toml — the buses, the cross-node signals and events, the routes and each node's
// identities (docs/multi-node.md). sysmodel parses it; this is what it may say.
pub const system = system_schema()

fn system_schema() Schema {
	return Schema{
		file: 'system.toml'
		root: 'sys_top'
		title: 'blobly_emb system configuration: the buses, cross-node signals and events, routes and node identities of a system of ECUs (docs/multi-node.md)'
		desc: 'A system of ECUs (docs/multi-node.md). A system that declares any `[[signal]]`, `[[route]]` or `[[frame]]`, or a node `endpoint`, is DISSOLVED: its nodes author only their internals and `sysgen` lowers the rest into each `gen-<node>.toml`. Otherwise it is COMPOSED from complete per-node ecu.toml files, and syscheck checks them against each other.'
		tables: [
			tbl('sys_top', '(top level)', "The sections of a system.toml. At least one bus and one node; `[[signal]]`, `[[frame]]` and `[[route]]` are the dissolution model's.", [
				sub('bus', .namedmap, 'sys_bus').doc('the system buses, one [bus.<name>] each; the name is how signals, frames, routes and nodes refer to it'),
				sub('node', .arr, 'sys_node').doc('the member ECUs'),
				sub('signal', .arr, 'sys_signal').doc('cross-node signals, declared once at system scope (dissolution)'),
				sub('frame', .arr, 'sys_frame').doc('SOME/IP events: id, signal set, tx mode and E2E trailer — a someip bus has no DBC to carry them'),
				sub('route', .arr, 'sys_route').doc('gateway routes between buses (dissolution only)'),
			]),
			tbl('sys_bus', '[bus.*]', 'One system bus: a CAN bus with its DBC, or a SOME/IP segment with its service.', [
				k('interface', .str).doc('the physical channel (SocketCAN name, driver channel); unique across buses — one system bus per wire'),
				k('kind', .str).d('"can"').one_of(['can', 'someip']).doc('the carrier: "can" (DBC frames) or "someip" (a service over Ethernet)'),
				k('fd', .boolean).d('false').doc("CAN-FD; in a composed system it must equal each member's own [bus] fd"),
				k('bitrate', .int).doc('nominal bitrate in bit/s — informational: syscheck prints it, nothing is generated from it'),
				k('dbc', .str).doc("the bus's frame contract, relative to system.toml; required on a CAN bus carrying a [[signal]], refused on someip"),
				k('service', .int).range(0, 0xFFFF).doc('someip: the SOME/IP service id (required on a someip bus, refused on CAN)'),
				k('version', .int).range(0, 0xFF).doc('someip: the interface version byte (required on a someip bus of a dissolved system, refused on CAN)'),
				sub('nm', .tbl, 'sys_bus_nm').doc("the bus's NM cluster (CAN only); without it a node's nm id generates a disabled [nm]"),
			]),
			tbl('sys_bus_nm', '[bus.*.nm]', "An NM cluster: the alive-id range and the timings every member shares. A timing absent (or <= 0) is not lowered, so the node takes loom2v's default.", [
				k('peers', .id_range).doc("[lo, hi] — the cluster's alive CAN ids; a member's alive id is lo + its nm; both at most 0x7FF"),
				k('msg_cycle_ms', .int).d('100').doc('NM message cycle (ms)'),
				k('timeout_ms', .int).d('300').doc('NM timeout (ms)'),
				k('repeat_ms', .int).d('200').doc('NM repeat-message time (ms)'),
				k('wait_sleep_ms', .int).d('150').doc('NM wait-bus-sleep time (ms)'),
			]),
			tbl('sys_signal', '[[signal]]', 'A cross-node signal, declared exactly once: who produces it, on which bus and in which frame.', [
				k('name', .str).doc('the signal name; FBs read and write it by this name'),
				k('fields', .str_map).doc('payload fields, name -> scalar type (bool, u8/i8, u16/i16, u32/i32, f32, f64; u64/i64 not on CAN); one value field on CAN'),
				k('producer', .str).doc('the node that transmits it; must be on `bus` and have an FB that writes it'),
				k('bus', .str).doc('the system bus it rides'),
				k('frame', .str).doc('CAN: the DBC message carrying it (sent by the producer); someip: the [[frame]] event carrying it'),
				k('cycle_ms', .int).d('100').doc('CAN tx cadence (ms); signals sharing a frame must agree; refused on someip (the [[frame]] tx says it)'),
			]),
			tbl('sys_node', '[[node]]', 'A member ECU and its system-owned identities.', [
				k('name', .str).doc("identifier, unique; the node's generated config is gen-<name>.toml"),
				k('ecu', .str).doc("the node's ecu.toml, relative to system.toml (internals only in a dissolved system)"),
				k('buses', .str_arr).d('[]').doc('the system buses it sits on; more than one CAN bus makes it a [[route]] gateway'),
				k('nm', .int).range(0, 0xFF).doc('its NM node id (alive = peers lo + nm); absent = not an NM node'),
				k('trace', .int).doc('its trace node id, unique across the system (checked only, not generated)'),
				sub('diag', .tbl, 'sys_diag').doc('its ISO-TP diagnostic ids, unique across the system (checked only, not generated)'),
				sub('endpoint', .tbl, 'sys_endpoint').doc('its network identity: the address SOME/IP and DoIP answer at'),
				sub('doip', .tbl, 'sys_doip').doc('the node is a DoIP entity at its endpoint address (lowered into [doip]; dissolved systems only)'),
			]),
			tbl('sys_diag', '[[node]] diag', '', [
				k('req', .int).doc('the diagnostic request CAN id'),
				k('rsp', .int).doc('the diagnostic response CAN id'),
			]),
			tbl('sys_endpoint', '[[node]] endpoint', '', [
				k('address', .str).doc('IPv4 dotted quad; unique per segment; a DoIP node needs a host address (not .0, .1 or .255)'),
				k('port', .int).range(1, 0xFFFF).doc('the SOME/IP listen port (required on a someip bus; not 13400 on a DoIP node)'),
			]),
			tbl('sys_doip', '[[node]] doip', 'The DoIP entity and its ISO 13400-2 transport policy (one parser for both files: tools/doipcfg; bounds: comm/doip policy.v).', doip_entity_keys('logical', 'functional')),
			tbl('sys_frame', '[[frame]]', 'A SOME/IP event on a someip bus: its id, its signals and how it is sent. Lowering copies only what it recognises, so an unknown key is refused.', [
				k('name', .str).doc('the event name; unique per bus'),
				k('bus', .str).doc('the someip bus it is on'),
				k('id', .int).range(0x8000, 0xFFFF).doc('the SOME/IP event id (bit 15 set; methods own 0x0001..0x7FFF); unique per bus'),
				k('signals', .str_arr).doc('its payload signals, in packing order; non-empty, all on the same bus'),
				sub('tx', .tbl, 'sys_frame_tx').doc('how the producer sends it; absent = cyclic every 100 ms'),
				sub('e2e', .tbl, 'sys_frame_e2e').doc('AUTOSAR E2E Profile 1 trailer'),
			]),
			tbl('sys_frame_tx', '[[frame]] tx', '', [
				k('mode', .str).d('"cyclic"').one_of(eth_tx_modes()).doc('how the producer sends it: periodically, on a change, or both (the event modes SOME/IP generates)'),
				k('cycle_ms', .int).d('100').range(1, 1_000_000).doc('the cadence (ms) of a cyclic or mixed event'),
				k('min_delay_ms', .int).d('0').range(0, 1_000_000).doc('the least gap between two event sends (ms)'),
			]),
			tbl('sys_frame_e2e', '[[frame]] e2e', '', [
				k('data_id', .int).range(0, 0xFFFF).doc('the E2E Data ID (required)'),
				k('counter_pos', .int).d('0').range(0, 0xFFFF).doc("the counter's byte offset in the payload"),
				k('crc_pos', .int).d('0').range(0, 0xFFFF).doc("the CRC's byte offset in the payload"),
				k('timeout_ms', .int).range(1, 2147483).doc('the receiver\'s sender-loss timeout (ms), longer than the cycle; required unless mode = "event"'),
			]),
			tbl('sys_route', '[[route]]', 'A gateway route between two buses (dissolution only): set exactly one of `frame` / `signal`.', [
				k('gateway', .str).doc('the node that forwards; it must sit on both buses'),
				k('frame', .str).doc('a raw frame route: the DBC message forwarded as it is (in both DBCs; not on an FD bus)'),
				k('signal', .str).doc('a signal route: the [[signal]] decoded on `from` and re-encoded on `to`'),
				k('from', .str).doc('the source bus'),
				k('to', .str).doc('the destination bus'),
			]),
		]
	}
}

// doip_entity_keys: a DoIP entity's address keys (named per file) and its transport policy. The
// policy keys are the same in ecu.toml's [doip] and a system node's `doip` (tools/doipcfg parses
// both); their bounds are comm/doip's, read from there.
// eth_tx_modes: the tx modes an event on an eth bus is generated with — com's TxMode less
// `triggered`, which has no generated trigger path (an ecu.toml eth [[frame]] obeys the same set)
pub fn eth_tx_modes() []string {
	return ['cyclic', 'event', 'mixed']
}

fn doip_entity_keys(logical string, functional string) []Key {
	mut keys := []Key{}
	keys << k(logical, .int).doc("the entity's logical address (0x0001..0x0DFF or 0x1000..0x7FFF); unique")
	keys << k(functional, .int).d('0xE400').range(0xE400, 0xEFFF).doc('the functional address it also answers')
	keys << doip_policy_keys()
	return keys
}

fn doip_policy_keys() []Key {
	return [
		k('testers', .int_arr).range(doip.tester_first, doip.tester_last).doc('tester addresses allowed to activate routing (at most ${doip.max_testers}); absent = any 0x0E00..0x0FFF'),
		k('activation_types', .int_arr).d('[0x00]').doc('routing activation types served: 0x00, 0x01, 0xE1..0xFF (at most ${doip.max_act_types})'),
		k('initial_inactivity_ms', .int).d('${doip.initial_inactivity_ms}').range(doip.initial_inactivity_min_ms, doip.initial_inactivity_max_ms).doc('T_TCP_Initial_Inactivity: time to activate after the TCP connect (ms); <= general_inactivity_ms'),
		k('general_inactivity_ms', .int).d('${doip.general_inactivity_ms}').range(doip.general_inactivity_min_ms, doip.general_inactivity_max_ms).doc('T_TCP_General_Inactivity: idle timeout once activated (ms)'),
		k('announce_count', .int).d('${doip.announce_count}').range(0, doip.announce_count_max).doc('A_DoIP_Announce_Num: vehicle announcements at start-up'),
		k('announce_interval_ms', .int).d('${doip.announce_interval_ms}').range(doip.announce_interval_min_ms, doip.announce_interval_max_ms).doc('A_DoIP_Announce_Interval (ms); count x interval at most ${doip.announce_total_max_ms} ms'),
		k('allow_bench_key', .boolean).d('false').doc("answer 0x27 with blobly_net's PUBLIC reference key over the network — a bench posture, opted into by name"),
	]
}
