module sysmodel

import os

// @verifies REQ-CAN-TP-023
// a gateway carries routed messages up to its own maximum message: system_full's zone_a, at 4095
// behind sysnode at the default 520, is the one route syscheck warns about — named by both nodes and
// what the gateway does with a longer request, a longer answer and the bootloader's blocks — and
// with equal sizes there is no such warning; nor with the gateway the larger, where the route
// carries the node's maximum and nothing the node takes is lost
fn test_a_routed_target_longer_than_its_gateway_is_warned_about() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_route_size_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	src := os.join_path(@VMODROOT, 'examples', 'system_full')
	os.mkdir_all(dir) or { panic(err) }
	for f in os.ls(src) or { [] } {
		if f.ends_with('.dbc') || f == 'system.toml' {
			os.cp(os.join_path(src, f), os.join_path(dir, f)) or { panic(err) }
		}
	}
	for n in os.ls(os.join_path(src, 'nodes')) or { [] } {
		e := os.join_path(src, 'nodes', n, 'ecu.toml')
		if os.exists(e) {
			os.mkdir_all(os.join_path(dir, 'nodes', n)) or { panic(err) }
			os.cp(e, os.join_path(dir, 'nodes', n, 'ecu.toml')) or { panic(err) }
		}
	}
	warned := size_warnings(dir)
	assert warned.len == 1, warned.str()
	assert warned[0].contains('node "sysnode": doip route to "zone_a"'), warned[0]
	assert warned[0].contains("max_message is 4095 and the gateway's 520"), warned[0]
	assert warned[0].contains("a request longer than 520 bytes is refused by the gateway's entity (generic NACK 0x02, the message discarded)"), warned[0]
	assert warned[0].contains('an answer longer than 520 bytes is answered responseTooLong (0x14)'), warned[0]
	assert warned[0].contains('TransferData blocks are lowered to 520 bytes'), warned[0]
	// zone_a at the default: nothing to say
	zone := os.join_path(dir, 'nodes', 'zone_a', 'ecu.toml')
	text := os.read_file(zone) or { panic(err) }
	assert text.contains('max_message   = 4095')
	os.write_file(zone, text.replace('max_message   = 4095', 'max_message   = 520')) or { panic(err) }
	assert size_warnings(dir).len == 0
	// the gateway at 4095 and zone_a at 520: nothing to say either
	gw := os.join_path(dir, 'nodes', 'sysnode', 'ecu.toml')
	gtext := os.read_file(gw) or { panic(err) }
	at := gtext.index('[isotp]\n') or { panic('sysnode has no [isotp]') }
	os.write_file(gw, gtext[..at + 8] + 'max_message = 4095\n' + gtext[at + 8..]) or { panic(err) }
	assert size_warnings(dir).len == 0
}

// size_warnings: the maximum-message warnings syscheck gives for the system in `dir`
fn size_warnings(dir string) []string {
	mut s := parse_system(os.join_path(dir, 'system.toml')) or { panic(err) }
	dissolved := s.signals.len > 0 || s.routes.len > 0 || s.frames.len > 0 || s.nodes.any(it.has_endpoint)
	errs := if dissolved { s.load_nodes_partial() } else { s.load_nodes() }
	assert errs.len == 0, errs.str()
	issues := if dissolved { validate_system_gen(s) } else { validate_system(s) }
	return issues.filter(it.req == 'REQ-CAN-TP-023').map(it.msg)
}
