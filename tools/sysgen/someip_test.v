module main

import os
import rand
import tools.sysmodel
import tools.ecumodel
import tools.doipcfg
import toml

// Lowering a someip member (#245). The system owns the segment's contract — the service and its
// events — because a someip bus has no DBC to own it, so sysgen emits what the CAN path takes
// from the DBC: the event id, its signal set, its tx mode and its E2E trailer.

fn tel_system() sysmodel.System {
	return sysmodel.System{
		buses:   [
			sysmodel.Bus{
				name:        'tel'
				kind:        'someip'
				service:     0x0100
				has_service: true
				version:     1
				has_version: true
			},
		]
		nodes:   [
			sysmodel.Node{
				name:         'tcu'
				ecu:          'nodes/tcu/ecu.toml'
				buses:        ['tel']
				endpoint:     '192.168.0.51'
				port:         30490
				port_raw:     30490
				has_port:     true
				has_endpoint: true
				view:         sysmodel.NodeView{
					fb_writes: ['BenchLoad']
					fb_reads:  ['LampCmd']
				}
			},
			sysmodel.Node{
				name:         'bench'
				ecu:          'nodes/bench/ecu.toml'
				buses:        ['tel']
				endpoint:     '192.168.0.190'
				port:         30491
				port_raw:     30491
				has_port:     true
				has_endpoint: true
				view:         sysmodel.NodeView{
					fb_writes: ['LampCmd']
					fb_reads:  ['BenchLoad']
				}
			},
		]
		signals: [
			sysmodel.SysSignal{
				name:     'BenchLoad'
				producer: 'tcu'
				bus:      'tel'
				frame:    'BenchTelem'
				fields:   {
					'load': 'u8'
				}
			},
			sysmodel.SysSignal{
				name:     'LampCmd'
				producer: 'bench'
				bus:      'tel'
				frame:    'BenchCmd'
				fields:   {
					'level': 'u8'
				}
			},
		]
		frames:  [
			sysmodel.SysFrame{
				name:            'BenchTelem'
				bus:             'tel'
				id:              0x8001
				id_raw:          0x8001
				has_id:          true
				signals:         ['BenchLoad']
				tx_mode:         'cyclic'
				cycle_ms:        300
				cycle_ms_raw:    300
				has_tx:          true
				has_cycle_ms:    true
				has_e2e:         true
				has_e2e_data_id: true
				e2e_data_id_int: true
				e2e_data_id:     0x21
				e2e_data_id_raw: 0x21
				e2e_counter:     1
				e2e_counter_raw: 1
				e2e_crc:         2
				e2e_crc_raw:     2
				has_e2e_timeout: true
				e2e_timeout_raw: 500
			},
			sysmodel.SysFrame{
				name:    'BenchCmd'
				bus:     'tel'
				id:      0x8010
				id_raw:  0x8010
				has_id:  true
				signals: ['LampCmd']
			},
		]
	}
}

// The fixture above is a VALID system: each refusal test below perturbs exactly one thing, so a
// failure names the rule that fired rather than the fixture's own gaps.
fn test_the_fixture_is_a_valid_segment() {
	assert seg_errs(tel_system()).len == 0, seg_errs(tel_system()).str()
}

fn test_the_producer_gets_its_endpoint_service_and_event() {
	sys := tel_system()
	out := generate_someip_node(sys, sys.nodes[0], sys.buses[0], sysmodel.NodeView{}, {
		'BenchLoad': 'app'
	}, '[target]\nkind = "threadx"') or { panic(err) }
	// its own address and port, and the service the BUS holds every member to
	assert out.contains('interface = "192.168.0.51"')
	assert out.contains('port    = 30490')
	assert out.contains('service = 0x100')
	// the peer is the OTHER member's endpoint — which is what makes reciprocity checkable
	assert out.contains('peer    = "192.168.0.190:30491"')
	// the event it produces, with the layout the system declared
	assert out.contains('id      = 0x8001')
	assert out.contains('tx      = { mode = "cyclic", cycle_ms = 300 }')
	assert out.contains('e2e     = { data_id = 0x21, counter_pos = 1, crc_pos = 2 }')
	// and the authored internals, appended verbatim
	assert out.contains('[target]')
}

// A frame's `tx` belongs to the PRODUCER. Emitted on a receiving node it would never publish,
// and loom2v refuses it for exactly that reason — so the rx side gets the event without a mode.
fn test_the_receiver_gets_the_event_without_a_tx_mode() {
	sys := tel_system()
	view := sysmodel.NodeView{
		fb_reads: ['BenchLoad']
	}
	out := generate_someip_node(sys, sys.nodes[1], sys.buses[0], view, {
		'BenchLoad': 'bench'
		'LampCmd':   'bench'
	}, '') or { panic(err) }
	assert out.contains('id      = 0x8001'), out
	assert !out.contains('tx      ='), 'a receiving node must not declare a tx mode:\n${out}'
	// ...and the direction is bus -> partition
	assert out.contains('from   = "eth0"')
	// the E2E sender-loss timeout is the RECEIVER's (REQ-E2E-002), and so is the receive status
	// the bridge fills — loom2v requires both on a received E2E frame
	assert out.contains('e2e     = { data_id = 0x21, counter_pos = 1, crc_pos = 2, timeout_ms = 500 }'), out
	assert out.contains('status = "RxStatus"'), out
	assert out.contains('lost = "u32"'), 'a generated receiver cannot see skipped frames:\n${out}'
}

// A lone member cannot be lowered: the generated bridge sends to ONE static peer and has no
// service discovery to find a second, so check_someip_segment refuses the segment rather than
// letting sysgen emit a config loom2v would reject for a missing `peer` (self-review on #245).
fn test_a_lone_member_segment_is_refused() {
	mut sys := tel_system()
	sys.nodes = [sys.nodes[0]]
	e := sysmodel.validate_system_gen(sys).filter(it.severity == .error).map(it.msg)
	assert e.any(it.contains('has 1 member(s)')), e.str()
}

// A third member is legal when an EVENT connects it: each event is point-to-point (one producer,
// one receiver), so a segment of three is pairs sharing one service. One that no event reaches
// has no peer to lower, and is refused.
fn third_member() sysmodel.Node {
	return sysmodel.Node{
		name:         'gw'
		buses:        ['tel']
		endpoint:     '192.168.0.50'
		port:         30490
		port_raw:     30490
		has_port:     true
		has_endpoint: true
		view:         sysmodel.NodeView{
			fb_writes: ['GwUptime']
		}
	}
}

// tel_system plus a third member publishing GwStatus to the bench — the system_full shape.
fn tel_system_of_three() sysmodel.System {
	mut sys := tel_system()
	sys.nodes << third_member()
	sys.nodes[1].view.fb_reads << 'GwUptime'
	sys.signals << sysmodel.SysSignal{
		name:     'GwUptime'
		producer: 'gw'
		bus:      'tel'
		frame:    'GwStatus'
		fields:   {
			'seconds': 'u32'
		}
	}
	sys.frames << sysmodel.SysFrame{
		name:    'GwStatus'
		bus:     'tel'
		id:      0x8020
		id_raw:  0x8020
		has_id:  true
		signals: ['GwUptime']
	}
	return sys
}

fn test_a_third_member_an_event_connects_is_a_valid_segment() {
	assert seg_errs(tel_system_of_three()).len == 0, seg_errs(tel_system_of_three()).str()
}

fn test_a_third_member_no_event_reaches_is_refused() {
	mut sys := tel_system()
	sys.nodes << sysmodel.Node{
		name:         'extra'
		buses:        ['tel']
		endpoint:     '192.168.0.60'
		port:         30492
		port_raw:     30492
		has_port:     true
		has_endpoint: true
	}
	e := seg_errs(sys)
	assert e.any(it.contains('"extra"') && it.contains('exchanges no event')), e.str()
}

// An event is UNICAST: two members reading one event would need a second destination the bridge
// does not have (no service discovery, no multicast).
fn test_an_event_read_by_two_members_is_refused() {
	mut sys := tel_system_of_three()
	sys.nodes[2].view.fb_reads << 'BenchLoad'
	e := seg_errs(sys)
	assert e.any(it.contains('event "BenchTelem" is read by 2 members')), e.str()
}

// ...and an event nobody reads has nowhere to go once the segment is larger than two.
fn test_an_event_no_member_reads_is_refused_on_a_larger_segment() {
	mut sys := tel_system_of_three()
	sys.nodes[1].view.fb_reads = sys.nodes[1].view.fb_reads.filter(it != 'GwUptime')
	e := seg_errs(sys)
	assert e.any(it.contains('no member receives event "GwStatus"')), e.str()
}

// The lowering: the member with two partners keeps the first one its events reach as [someip].peer
// (tcu, by BenchTelem's place in the system) and names the other on the event it exchanges with it.
fn test_a_member_with_two_partners_gets_a_peer_per_event() {
	sys := tel_system_of_three()
	bench := sys.nodes[1]
	out := generate_someip_node(sys, bench, sys.buses[0], bench.view, {
		'LampCmd':   'bench'
		'BenchLoad': 'bench'
		'GwUptime':  'bench'
	}, '') or { panic(err) }
	assert out.contains('peer    = "192.168.0.51:30490"'), out
	gw := out.index('name    = "GwStatus"') or { panic('GwStatus not lowered:\n${out}') }
	assert out[gw..].contains('peer    = "192.168.0.50:30490"'), out
	// tcu's own events carry no per-event peer: tcu is the default
	tl := out.index('name    = "BenchTelem"') or { panic(out) }
	assert !out[tl..gw].contains('peer'), out
	// ...and a member with ONE partner lowers exactly as a segment of two always has
	g := sys.nodes[2]
	gout := generate_someip_node(sys, g, sys.buses[0], g.view, {
		'GwUptime': 'gateway'
	}, '') or { panic(err) }
	assert gout.contains('peer    = "192.168.0.190:30491"'), gout
	assert gout.count('peer    =') == 1, gout
}

// Two members answering at one address is an ARP conflict on the segment, and the generated
// configs would both claim it.
fn test_duplicate_endpoints_are_refused() {
	mut sys := tel_system()
	sys.nodes[1].endpoint = sys.nodes[0].endpoint
	e := sysmodel.validate_system_gen(sys).filter(it.severity == .error).map(it.msg)
	assert e.any(it.contains('both answer at')), e.str()
}

// NM is a CAN cluster protocol: an [nm] on a someip member would ride a generated config
// nothing serves.
fn test_nm_on_a_someip_member_is_refused() {
	mut sys := tel_system()
	sys.nodes[0].nm = 0x14
	sys.nodes[0].has_nm_alloc = true
	e := sysmodel.validate_system_gen(sys).filter(it.severity == .error).map(it.msg)
	assert e.any(it.contains('has no NM')), e.str()
}

// An event is received WHOLE — one datagram at fixed offsets — so a partial subscriber is
// REFUSED rather than lowered: dropping the unread signals would shift the offsets of the ones
// it does read, and declaring them anyway creates rx channels with no reading handler, which
// the generated-config gate rejects (codex on #245).
fn test_a_partial_subscriber_is_refused() {
	mut sys := tel_system()
	sys.signals << sysmodel.SysSignal{
		name:     'BenchTicks'
		producer: 'tcu'
		bus:      'tel'
		frame:    'BenchTelem'
		fields:   {
			'ticks': 'u32'
		}
	}
	sys.frames[0].signals = ['BenchLoad', 'BenchTicks']
	sys.nodes[1].view.fb_reads = ['BenchLoad'] // reads ONE of the two
	e := sysmodel.validate_system_gen(sys).filter(it.severity == .error).map(it.msg)
	assert e.any(it.contains('no FB reads "BenchTicks"')), e.str()
}

// ...and a whole-event subscriber gets every signal of it declared, so the payload offsets the
// producer packed are the offsets it decodes.
fn test_a_whole_event_subscriber_declares_every_signal() {
	mut sys := tel_system()
	sys.signals << sysmodel.SysSignal{
		name:     'BenchTicks'
		producer: 'tcu'
		bus:      'tel'
		frame:    'BenchTelem'
		fields:   {
			'ticks': 'u32'
		}
	}
	sys.frames[0].signals = ['BenchLoad', 'BenchTicks']
	view := sysmodel.NodeView{
		fb_reads: ['BenchLoad', 'BenchTicks']
	}
	out := generate_someip_node(sys, sys.nodes[1], sys.buses[0], view, {
		'BenchLoad':  'bench'
		'BenchTicks': 'bench'
		'LampCmd':    'bench'
	}, '') or { panic(err) }
	assert out.contains('name   = "BenchLoad"')
	assert out.contains('name   = "BenchTicks"'), out
}

// `tx = { cycle_ms = 300 }` is valid shorthand: gating on a non-empty mode dropped the whole
// table and the node silently ran on loom2v's 100 ms default (codex on #245).
fn test_a_tx_table_without_a_mode_survives_lowering() {
	mut sys := tel_system()
	sys.frames[0].tx_mode = ''
	out := generate_someip_node(sys, sys.nodes[0], sys.buses[0], sysmodel.NodeView{}, {
		'BenchLoad': 'app'
	}, '') or { panic(err) }
	assert out.contains('tx      = { cycle_ms = 300 }'), out
}

// An event carrying no signals is lowered into no node at all — a system-declared contract that
// silently does not exist.
fn test_an_event_with_no_signals_is_refused() {
	mut sys := tel_system()
	sys.frames << sysmodel.SysFrame{
		name:   'Empty'
		bus:    'tel'
		id:     0x8020
		has_id: true
	}
	e := sysmodel.validate_system_gen(sys).filter(it.severity == .error).map(it.msg)
	assert e.any(it.contains('declares no `signals`')), e.str()
}

// Two members spelling one address differently still collide on the wire.
fn test_endpoints_are_compared_canonically() {
	mut sys := tel_system()
	sys.nodes[1].endpoint = '192.168.000.051'
	e := sysmodel.validate_system_gen(sys).filter(it.severity == .error).map(it.msg)
	assert e.any(it.contains('both answer at')), e.str()
}

// LOWERING IS RE-SERIALIZATION, so whatever the parser normalizes away is a wire contract the
// target never sees. These pin the four ways that bit (codex on #245 r2).

fn seg_errs(sys sysmodel.System) []string {
	return sysmodel.validate_system_gen(sys).filter(it.severity == .error).map(it.msg)
}

// u32() turned an out-of-range id into a legal-looking one, which then passed the generated
// config's own 16-bit check and transmitted under an id nobody declared.
fn test_an_event_id_wider_than_the_header_is_refused() {
	mut sys := tel_system()
	sys.frames[0].id_raw = 0x100008001
	assert seg_errs(sys).any(it.contains('is not a SOME/IP event id')), seg_errs(sys).str()
}

fn test_an_out_of_range_endpoint_port_is_refused() {
	mut sys := tel_system()
	sys.nodes[0].port_raw = 70000
	assert seg_errs(sys).any(it.contains("is outside 1..65535")), seg_errs(sys).str()
}

// A typo is DISCARDED by a parser that copies only what it recognises: `e2ee` would silently
// mean "no E2E", and the generated file no longer carries the misspelling for ecucheck to see.
fn test_an_unknown_frame_key_is_refused() {
	mut sys := tel_system()
	sys.frames[0].unknown_keys = ['e2ee']
	assert seg_errs(sys).any(it.contains('unknown key "e2ee"')), seg_errs(sys).str()
}

// 0 is a legal E2E data id, so a defaulted one is indistinguishable from a declared one once
// written out — the authored form rejects the omission, and so must this.
fn test_an_e2e_table_without_a_data_id_is_refused() {
	mut sys := tel_system()
	sys.frames[0].has_e2e_data_id = false
	assert seg_errs(sys).any(it.contains('no `data_id`')), seg_errs(sys).str()
}

// The EVENT transmits, and several signals share one, so a signal-level cadence would be
// accepted by the CAN-shaped checks and then lowered nowhere.
fn test_a_signal_level_cadence_on_someip_is_refused() {
	mut sys := tel_system()
	sys.signals[0].cycle_ms = 300
	sys.signals[0].has_cycle_ms = true // presence is what is rejected: an explicit -1 counts too
	assert seg_errs(sys).any(it.contains('the EVENT is what transmits')), seg_errs(sys).str()
}

// An event id must carry the EVENT CLASS bit, not merely fit 16 bits: a signal frame is an
// event, and the generated gate says so — checking only the width let syscheck report OK on a
// config sysgen then refused (codex on #245 r4).
fn test_a_method_class_id_is_refused_for_a_signal_frame() {
	mut sys := tel_system()
	sys.frames[0].id_raw = 0x1234
	assert seg_errs(sys).any(it.contains('is not a SOME/IP event id')), seg_errs(sys).str()
}

// The E2E TRAILER POSITIONS narrow like every other number: 4294967303 became 7, a legal offset
// for the reference payload, silently relocating the counter.
fn test_an_out_of_range_e2e_position_is_refused() {
	mut sys := tel_system()
	sys.frames[0].e2e_counter_raw = 4294967303
	assert seg_errs(sys).any(it.contains('counter_pos')), seg_errs(sys).str()
}

// 0 is a legal interface version, so an omitted one becomes a real wire version once lowered.
fn test_a_someip_bus_without_a_version_is_refused() {
	mut sys := tel_system()
	sys.buses[0].has_version = false
	assert seg_errs(sys).any(it.contains('needs a `version`')), seg_errs(sys).str()
}

fn test_an_endpoint_without_a_port_is_refused() {
	mut sys := tel_system()
	sys.nodes[0].has_port = false
	assert seg_errs(sys).any(it.contains('has no `port`')), seg_errs(sys).str()
}

// Lowering keys emitted frames by NAME, so a duplicate is suppressed while its signals are
// still emitted — the signal then rides no frame and only the generated gate notices.
fn test_two_frames_with_one_generated_name_are_refused() {
	mut sys := tel_system()
	sys.frames << sysmodel.SysFrame{
		name:    'Bench_Telem' // snake()s to the same identifier as BenchTelem
		bus:     'tel'
		id:      0x8002
		id_raw:  0x8002
		has_id:  true
		signals: ['LampCmd']
	}
	assert seg_errs(sys).any(it.contains('same generated name')), seg_errs(sys).str()
}

// ROUND 5. Each of these is a rule the NODE build already enforces (ecumodel.validate_someip) or
// a shape the lowering cannot express — caught here so syscheck cannot report OK on a system
// that sysgen or the node build then refuses.

// .i64() coerces a non-integer to 0, and 0 is a legal E2E identity: the type error would survive
// lowering as an explicit `data_id = 0` that reads exactly like a declared one.
fn test_a_non_integer_e2e_data_id_is_refused() {
	mut sys := tel_system()
	sys.frames[0].e2e_data_id_int = false
	assert seg_errs(sys).any(it.contains('data_id must be an integer')), seg_errs(sys).str()
}

// A node that keeps its authored [someip] through the migration gets TWO of them: the lowering
// emits one and appends the authored file verbatim after it. syscheck must say so, because
// sysgen only discovers it while writing the output.
fn test_a_node_that_kept_its_authored_someip_table_is_refused() {
	mut sys := tel_system()
	sys.nodes[0].view.has_someip = true
	errs := sysmodel.validate_system_gen(sys).filter(it.severity == .error).map(it.msg)
	assert errs.any(it.contains('[someip]')), errs.str()
}

// A segment member MAY also sit on one CAN bus: it is a LEAF on both and the lowering carries
// both halves in one file (nodes/tester — an LED on compute, tcu's peer on tel).
fn test_a_someip_member_may_be_a_leaf_on_one_can_bus() {
	mut sys := tel_system()
	sys.buses << sysmodel.Bus{
		name:      'pt'
		kind:      'can'
		interface: 'can0'
	}
	sys.nodes[0].buses << 'pt'
	assert sys.is_someip_leaf(sys.nodes[0])
	assert seg_errs(sys).len == 0, seg_errs(sys).str()
}

// A CAN<->CAN route GATEWAY may be a member too (system_full's sysnode): its routes stay on CAN,
// and its own events on the segment are lowered beside them. What stays refused is a route that
// TOUCHES the segment — translating between CAN and SOME/IP is its own rung.
fn gateway_member_system() sysmodel.System {
	mut sys := tel_system_of_three()
	for nm in ['pt', 'body'] {
		sys.buses << sysmodel.Bus{
			name:      nm
			kind:      'can'
			interface: if nm == 'pt' { 'can0' } else { 'can1' }
		}
		sys.nodes[2].buses << nm
	}
	sys.routes << sysmodel.Route{
		gateway: 'gw'
		frame:   'Fwd'
		from:    'pt'
		to:      'body'
	}
	return sys
}

fn test_a_can_route_gateway_may_be_a_someip_member() {
	sys := gateway_member_system()
	assert !sys.is_someip_leaf(sys.nodes[2])
	// the segment's own rules are satisfied; the CAN routes are not this test's subject
	e := seg_errs(sys).filter(it.contains('someip') || it.contains('segment') || it.contains('tel'))
	assert e.len == 0, e.str()
}

fn test_a_gateway_member_is_lowered_with_both_halves() {
	sys := gateway_member_system()
	g := sys.nodes[2]
	out := generate_gateway_node(sys, g, '[target]\nkind = "threadx"', g.view, {
		'GwUptime': 'gateway'
	}) or { panic(err) }
	// its CAN buses, and no CAN-shaped table for the segment
	assert out.contains('[bus.can0]') && out.contains('[bus.can1]'), out
	assert !out.contains('[bus.]'), out
	// the route, and the SOME/IP half
	assert out.contains('from = { bus = "can0", frame = "Fwd" }'), out
	assert out.contains('[bus.eth0]') && out.contains('interface = "192.168.0.50"'), out
	assert out.contains('peer    = "192.168.0.190:30491"'), out
	assert out.contains('name    = "GwStatus"'), out
	assert out.contains('to     = "eth0"'), out
}

// ...but the gateway's FB may still not read or write a CAN system signal (not generated yet).
fn test_a_gateway_member_fb_on_a_can_signal_is_still_refused() {
	mut sys := gateway_member_system()
	sys.signals << sysmodel.SysSignal{
		name:     'Speed'
		producer: 'gw'
		bus:      'pt'
		fields:   {
			'kph': 'u32'
		}
	}
	sys.nodes[2].view.fb_writes << 'Speed'
	assert seg_errs(sys).any(it.contains('reads/writes system signal "Speed"')), seg_errs(sys).str()
}

fn test_a_route_across_the_segment_is_refused() {
	mut sys := tel_system()
	sys.buses << sysmodel.Bus{
		name:      'pt'
		kind:      'can'
		interface: 'can0'
	}
	sys.nodes[0].buses << 'pt'
	sys.routes << sysmodel.Route{
		gateway: 'tcu'
		signal:  'BenchLoad'
		from:    'pt'
		to:      'tel'
	}
	assert !sys.is_someip_leaf(sys.nodes[0])
	assert seg_errs(sys).any(it.contains('routing across a SOME/IP bus is not generated yet')), seg_errs(sys).str()
}

// ...and so is a member carrying SEVERAL CAN buses that routes nothing between them.
fn test_a_someip_member_on_two_can_buses_is_refused() {
	mut sys := tel_system()
	for nm in ['pt', 'body'] {
		sys.buses << sysmodel.Bus{
			name:      nm
			kind:      'can'
			interface: 'can0'
		}
		sys.nodes[0].buses << nm
	}
	assert seg_errs(sys).any(it.contains('sits on 2 CAN buses but routes nothing')), seg_errs(sys).str()
}

// The service and the version are the segment's IDENTITY, and .i64() coerces a non-integer to
// 0 — a legal id and a legal version. Lowering would write an explicit numeric 0 that the node
// gate cannot tell from a declared one, so the type has to be caught while the evidence exists
// (codex on #245 round 6, in the review BODY rather than inline).
fn test_a_non_integer_service_is_refused() {
	mut sys := tel_system()
	sys.buses[0].service_int = false
	assert seg_errs(sys).any(it.contains('`service` must be an integer')), seg_errs(sys).str()
}

fn test_a_non_integer_version_is_refused() {
	mut sys := tel_system()
	sys.buses[0].version_int = false
	assert seg_errs(sys).any(it.contains('`version` must be an integer')), seg_errs(sys).str()
}

// A cadence is an INTEGER. .i64() drops the type and the fraction together, so 300.5 would
// lower as a perfectly legal 300 — and ecumodel's own `!is i64` check sees only the lowered
// integer, so nothing downstream could tell the wire contract from the authored one.
fn test_a_non_integer_cadence_is_refused() {
	mut sys := tel_system()
	sys.frames[0].cycle_ms_int = false
	assert seg_errs(sys).any(it.contains('cycle_ms must be an integer')), seg_errs(sys).str()
}

fn test_a_non_integer_min_delay_is_refused() {
	mut sys := tel_system()
	sys.frames[1].has_min_delay_ms = true
	sys.frames[1].min_delay_ms_int = false
	assert seg_errs(sys).any(it.contains('min_delay_ms must be an integer')), seg_errs(sys).str()
}

// --out stages a self-contained tree, so a DBC path that CLIMBS out of it must be refused
// rather than copied: `../shared.dbc` joined to the scratch dir resolves outside it, and the
// copy would then overwrite whatever sits at that name (codex on #279).
fn test_a_dbc_path_escaping_the_output_dir_is_refused() {
	// the system dir is a SUBDIRECTORY of temp, so "../escape.dbc" resolves to a real file
	// one level up — otherwise copy_dbcs skips it as missing and never reaches the check
	// ONE unique root per run, everything beneath it. Shared /tmp names would collide between
	// overlapping runs and — worse — the cleanup would delete another process's files.
	root := os.join_path(os.temp_dir(), 'syscheck_trav_${os.getpid()}_${rand.u32()}')
	sysdir := os.join_path(root, 'sys')
	dst := os.join_path(root, 'out')
	src := os.join_path(root, 'escape.dbc') // what "../escape.dbc" resolves to from sysdir
	os.mkdir_all(sysdir) or { panic('mkdir: ${err}') }
	os.mkdir_all(dst) or { panic('mkdir: ${err}') }
	os.write_file(src, '') or { panic('seed: ${err}') }
	defer {
		os.rmdir_all(root) or {}
	}
	mut sys := tel_system()
	sys.dir = sysdir
	sys.buses << sysmodel.Bus{
		name:      'pt'
		kind:      'can'
		interface: 'can0'
		dbc:       '../escape.dbc'
	}
	copy_dbcs(sys, dst) or {
		assert err.msg().contains('resolves outside the output directory'), err.msg()
		return
	}
	assert false, 'a DBC path climbing out of the output directory must be refused'
}

// THE GUARD FOR THE WHOLE CLASS. Three review rounds found the same defect in nine separate
// numeric fields, one at a time: a narrowing conversion (.int()/.i64()) turns a float or a
// string into a LEGAL value of that field, the lowering re-serialises it as an integer, and the
// node gate's own type check then sees nothing wrong — the evidence exists only in the parser.
//
// So rather than wait for round four to name the tenth field: every `*_raw` field on SysFrame
// keeps a pre-narrowing value, and every one of them must have an `*_int` sibling recording
// whether the author actually wrote an integer. Adding a raw field without one fails HERE, at
// compile time, instead of on the wire.
fn test_every_raw_field_has_an_integer_type_flag() {
	mut raws := []string{}
	mut ints := []string{}
	$for f in sysmodel.SysFrame.fields {
		if f.name.ends_with('_raw') {
			raws << f.name#[..-4]
		}
		if f.name.ends_with('_int') {
			ints << f.name#[..-4]
		}
	}
	mut missing := []string{}
	for r in raws {
		if r !in ints {
			missing << r + '_raw'
		}
	}
	assert missing.len == 0, 'SysFrame fields with no *_int sibling: ${missing} — a narrowed value is always a LEGAL value, so the authored type must be recorded beside it'
	assert raws.len >= 5, 'the guard found only ${raws.len} raw fields — comptime field iteration is not doing what this test assumes'
}

// An endpoint port is narrowed too: 30490.5 truncates to a valid, DIFFERENT port.
fn test_a_non_integer_port_is_refused() {
	mut sys := tel_system()
	sys.nodes[0].port_int = false
	assert seg_errs(sys).any(it.contains('`port` must be an integer')), seg_errs(sys).str()
}

// ...and so is an event id: 32769.5 truncates to the perfectly valid 0x8001.
fn test_a_non_integer_event_id_is_refused() {
	mut sys := tel_system()
	sys.frames[0].id_int = false
	assert seg_errs(sys).any(it.contains('`id` must be an integer')), seg_errs(sys).str()
}

// ...and the trailer offsets: 1.5 truncates to the valid offset 1.
fn test_non_integer_trailer_offsets_are_refused() {
	mut sys := tel_system()
	sys.frames[0].e2e_counter_int = false
	assert seg_errs(sys).any(it.contains('counter_pos/crc_pos must be integers')), seg_errs(sys).str()
}

// A node name becomes gen-<name>.toml, so it must be an identifier — otherwise the write escapes
// the output directory entirely.
fn test_a_node_name_that_is_a_path_is_refused() {
	mut sys := tel_system()
	sys.nodes[0].name = '../../../victim'
	assert seg_errs(sys).any(it.contains('is not an identifier')), seg_errs(sys).str()
}

// A LEAF on one CAN bus and one segment MAY allocate nm: its CAN traffic must observe
// coordinated sleep like any other member's, and the lowering emits the [nm] against that bus.
fn test_a_someip_leaf_may_allocate_nm_for_its_can_bus() {
	mut sys := tel_system()
	sys.buses << sysmodel.Bus{
		name:      'pt'
		kind:      'can'
		interface: 'can0'
	}
	sys.nodes[0].buses << 'pt'
	sys.nodes[0].has_nm_alloc = true
	sys.nodes[0].nm = 0x11
	assert seg_errs(sys).len == 0, seg_errs(sys).str()
}

// ...but a segment-ONLY member still may not: there is no SOME/IP network management.
fn test_a_segment_only_member_may_not_allocate_nm() {
	mut sys := tel_system()
	sys.nodes[0].has_nm_alloc = true
	sys.nodes[0].nm = 0x11
	assert seg_errs(sys).any(it.contains('has no NM')), seg_errs(sys).str()
}

// `tx` as a scalar reads as an EMPTY table, which lowers to `tx = { }` and the node gate then
// applies its own default cyclic 100ms — a cadence nobody authored.
fn test_a_tx_that_is_not_a_table_is_refused() {
	mut sys := tel_system()
	sys.frames[0].tx_is_table = false
	assert seg_errs(sys).any(it.contains('`tx` must be a table')), seg_errs(sys).str()
}

// A generated ThreadX member of an NM-managed CAN bus must allocate `nm`, and being a someip
// LEAF must not exempt it: the leaf exemption is for the GATEWAY-only rules. It was a bare
// `continue` for one round, which skipped every CAN-side check for the node.
fn test_a_someip_leaf_on_an_nm_bus_must_still_allocate_nm() {
	mut sys := tel_system()
	sys.buses << sysmodel.Bus{
		name:            'pt'
		kind:            'can'
		interface:       'can0'
		has_nm_cluster:  true
		nm_peers_lo:     0x500
		nm_peers_hi:     0x53f
	}
	sys.nodes[0].buses << 'pt'
	sys.nodes[0].view.is_threadx = true
	assert sys.is_someip_leaf(sys.nodes[0])
	assert seg_errs(sys).any(it.contains('must allocate `nm`')), seg_errs(sys).str()
}

// ...and the CAN-side rules are judged against the CAN bus whatever order the buses came in.
fn test_the_can_side_rules_find_the_can_bus_in_either_order() {
	mut sys := tel_system()
	sys.buses << sysmodel.Bus{
		name:           'pt'
		kind:           'can'
		interface:      'can0'
		has_nm_cluster: true
		nm_peers_lo:    0x500
		nm_peers_hi:    0x53f
	}
	// the segment FIRST, so buses[0] is the someip bus and a naive primary-bus lookup misses
	sys.nodes[0].buses = ['tel', 'pt']
	sys.nodes[0].view.is_threadx = true
	assert seg_errs(sys).any(it.contains('must allocate `nm`')), seg_errs(sys).str()
}

// The containment check must not reject the ORDINARY case. Invoked from the system directory,
// sys.dir is "." — normalising alone leaves the root as "." and the target as a bare filename,
// so a prefix test on "./" refuses the in-directory output that has always worked.
fn test_a_relative_output_directory_is_inside_itself() {
	assert inside('.', 'gen-node.toml')
	assert inside('.', './gen-node.toml')
	assert inside('out', 'out/gen-node.toml')
	assert inside('out', 'out')
	assert inside('/', '/gen-node.toml')
	assert !inside('.', '../gen-node.toml')
	assert !inside('out', 'gen-node.toml')
	assert !inside('/tmp/a', '/tmp/ab/gen-node.toml')
}

// --out INTO the system directory: src and target are the same file, so the copy must be
// skipped rather than attempted (os.cp onto itself either fails or truncates the authored
// contract). Containment still runs first, so this cannot become a way past it.
fn test_out_into_the_system_dir_skips_the_self_copy() {
	root := os.join_path(os.temp_dir(), 'syscheck_selfcopy_${os.getpid()}_${rand.u32()}')
	os.mkdir_all(root) or { panic('mkdir: ${err}') }
	defer {
		os.rmdir_all(root) or {}
	}
	dbc := os.join_path(root, 'bus.dbc')
	os.write_file(dbc, 'BO_ 1 X: 8 Y\n') or { panic('seed: ${err}') }
	mut sys := tel_system()
	sys.dir = root
	sys.buses << sysmodel.Bus{
		name:      'pt'
		kind:      'can'
		interface: 'can0'
		dbc:       'bus.dbc'
	}
	copy_dbcs(sys, root) or { assert false, 'a self-copy must be skipped, not attempted: ${err}' }
	// the authored contract is intact, not truncated
	assert os.read_file(dbc) or { '' } == 'BO_ 1 X: 8 Y\n'
}

// A scratch directory must be created ATOMICALLY and privately: a predictable name can be
// pre-staged by another process with symlinks that write_file/cp then follow out of the tree.
fn test_a_private_temp_dir_is_unique_exclusive_and_0700() {
	a := sysmodel.private_temp_dir('syscheck_probe') or { panic(err) }
	b := sysmodel.private_temp_dir('syscheck_probe') or { panic(err) }
	defer {
		os.rmdir_all(a) or {}
		os.rmdir_all(b) or {}
	}
	assert a != b, 'two calls must not collide'
	assert os.is_dir(a) && os.is_dir(b)
	// creating it IS the exclusivity check: mkdir(2) fails with EEXIST, so the same path
	// cannot be handed out twice or adopted from a pre-staged directory
	mut exclusive := false
	os.mkdir(a, os.MkdirParams{ mode: 0o700 }) or { exclusive = true }
	assert exclusive, 'mkdir on an existing scratch directory must fail — that is what makes creation the check'
	perms := os.execute('stat -c %a ${a}').output.trim_space()
	assert perms == '700', 'scratch dir must be private (700), got ${perms}'
}

// E2E's own sender-loss timeout (REQ-E2E-002) is required on a someip E2E frame, as loom2v
// requires it on the receiving node, and must outlast the sender's cycle or it fires between
// healthy frames
fn test_a_someip_e2e_frame_needs_a_timeout_longer_than_its_cycle() {
	mut sys := tel_system()
	sys.frames[0].has_e2e_timeout = false
	assert seg_errs(sys).any(it.contains('has no timeout_ms')), seg_errs(sys).str()
	sys.frames[0].has_e2e_timeout = true
	sys.frames[0].e2e_timeout_raw = 300 // the fixture's cycle_ms
	assert seg_errs(sys).any(it.contains('is not longer than its cycle (300 ms)')), seg_errs(sys).str()
	// a frame with no cycle_ms sends at loom2v's 100 ms default: that is the cycle to beat
	sys.frames[0].has_cycle_ms = false
	sys.frames[0].e2e_timeout_raw = 50
	assert seg_errs(sys).any(it.contains('is not longer than its cycle (100 ms)')), seg_errs(sys).str()
	sys.frames[0].has_cycle_ms = true
	sys.frames[0].e2e_timeout_raw = 0
	assert seg_errs(sys).any(it.contains('is not a timeout in ms')), seg_errs(sys).str()
	// and an event-only producer has no heartbeat for the timeout to watch
	sys.frames[0].e2e_timeout_raw = 1000
	sys.frames[0].tx_mode = 'event'
	assert seg_errs(sys).any(it.contains('needs a heartbeat')), seg_errs(sys).str()
}

// ---- doip on a [[node]] (rung 6) ----

// A node's DoIP server is declared on its [[node]] — `doip = { logical = 0x07A0 }` — and its
// address is the node's endpoint, so a node has ONE network identity, declared once in
// system.toml and lowered into [doip] (rung 6). What the node gate would refuse only once the node
// is BUILT is refused at the system, and what no single node can see — two entities at one
// logical address — is refused only there.

// doip_system: tel_system with tcu serving DoIP — a ThreadX node with one [isotp] connection
// and a diag allocation, which is what DoIP carries.
fn doip_system() sysmodel.System {
	mut sys := tel_system()
	sys.nodes[0].has_doip = true
	sys.nodes[0].has_doip_logical = true
	sys.nodes[0].doip_logical = 0x07A0
	sys.nodes[0].doip_logical_raw = 0x07A0
	sys.nodes[0].diag = sysmodel.Diag{
		req: 0x7A0
		rsp: 0x7A8
	}
	sys.nodes[0].view.is_threadx = true
	sys.nodes[0].view.isotp_conns = [sysmodel.IsotpConn{
		iface: 'can0'
		rx_id: 0x7A0
		tx_id: 0x7A8
	}]
	// the service table a [doip] node must declare (REQ-NET-012): 0x11 behind a level
	sys.nodes[0].view.uds_table = true
	sys.nodes[0].view.uds_rows = [doipcfg.ServiceRow{
		sid: 0x10
	}, doipcfg.ServiceRow{
		sid:      0x11
		security: 1
	}, doipcfg.ServiceRow{
		sid: 0x22
	}, doipcfg.ServiceRow{
		sid: 0x27
	}, doipcfg.ServiceRow{
		sid: 0x3E
	}]
	return sys
}

// REQ-NET-012 at the system, by the rule the node gate applies (doipcfg): a node serving `doip`
// declares a [uds] services table, every row that changes ECU state carries a security level, and
// the public bench key is used over the network only by name
fn test_a_doip_node_gates_every_state_change_and_names_a_bench_key() {
	mut sys := doip_system()
	sys.nodes[0].view.uds_table = false
	assert doip_errs(sys).any(it.contains('has no [uds] services table')), doip_errs(sys).str()
	sys = doip_system()
	sys.nodes[0].view.uds_rows[1] = doipcfg.ServiceRow{
		sid: 0x11
	}
	assert doip_errs(sys).any(it.contains('[uds] services 0x11 changes ECU state')), doip_errs(sys).str()
	// a read, a session, the authentication itself: open
	sys = doip_system()
	sys.nodes[0].view.uds_rows << doipcfg.ServiceRow{
		sid: 0x19
	}
	assert doip_errs(sys).len == 0, doip_errs(sys).str()
	// the bench key: refused unless allowed, and the allowance means nothing without it
	sys = doip_system()
	sys.nodes[0].view.uds_security_key = 'reference'
	assert doip_errs(sys).any(it.contains('PUBLIC bench key')), doip_errs(sys).str()
	sys.nodes[0].doip_policy.allow_bench_key = true
	sys.nodes[0].doip_policy.has_allow_bench_key = true
	assert doip_errs(sys).len == 0, doip_errs(sys).str()
	assert doip_section(sys.nodes[0]).contains('allow_bench_key = true')
	sys.nodes[0].view.uds_security_key = ''
	assert doip_errs(sys).any(it.contains('it would mean nothing')), doip_errs(sys).str()
}

fn doip_errs(sys sysmodel.System) []string {
	return seg_errs(sys).filter(it.contains('doip') || it.contains('DoIP'))
}

fn test_the_doip_fixture_is_valid() {
	assert doip_errs(doip_system()).len == 0, doip_errs(doip_system()).str()
}

fn test_doip_is_lowered_at_the_endpoint_address() {
	sys := doip_system()
	out := generate_someip_node(sys, sys.nodes[0], sys.buses[0], sysmodel.NodeView{}, {
		'BenchLoad': 'app'
	}, '') or { panic(err) }
	assert out.contains('[doip]\naddress         = "192.168.0.51"\nlogical_address = 0x7A0\n'), out
	assert !out.contains('functional_address'), out
	// and only where it is declared
	b := sys.nodes[1]
	bout := generate_someip_node(sys, b, sys.buses[0], b.view, {
		'LampCmd':   'bench'
		'BenchLoad': 'bench'
	}, '') or { panic(err) }
	assert !bout.contains('[doip]'), bout
}

fn test_a_functional_address_is_carried_through() {
	mut sys := doip_system()
	sys.nodes[0].has_doip_functional = true
	sys.nodes[0].doip_functional = 0xE400
	sys.nodes[0].doip_functional_raw = 0xE400
	assert doip_errs(sys).len == 0, doip_errs(sys).str()
	assert doip_section(sys.nodes[0]).contains('functional_address = 0xE400')
}

fn test_doip_needs_a_logical_address_in_the_entity_ranges() {
	mut sys := doip_system()
	sys.nodes[0].has_doip_logical = false
	assert doip_errs(sys).any(it.contains('doip needs `logical`')), doip_errs(sys).str()
	for bad in [i64(0), 0x0E00, 0x0FFF, 0x8000, 0xE400] {
		sys = doip_system()
		sys.nodes[0].doip_logical_raw = bad
		sys.nodes[0].doip_logical = u32(bad)
		assert doip_errs(sys).any(it.contains('is not an entity address')), '0x${bad.hex()}: ${doip_errs(sys)}'
	}
	sys = doip_system()
	sys.nodes[0].doip_logical_int = false
	assert doip_errs(sys).any(it.contains('`logical` must be an integer')), doip_errs(sys).str()
}

// the entity's ISO 13400-2 transport policy is the system's too: lowered one-to-one into [doip]
// under the same names, absent keys left to comm/doip's defaults
fn test_the_doip_transport_policy_is_lowered() {
	mut sys := doip_system()
	sys.nodes[0].doip_policy = doipcfg.Policy{
		testers:     [i64(0x0E00), 0x0E80]
		has_testers: true
		types:       [i64(0x00), 0xE1]
		has_types:   true
		ints:        {
			'general_inactivity_ms': i64(60000)
			'announce_count':        0
		}
	}
	assert doip_errs(sys).len == 0, doip_errs(sys).str()
	sec := doip_section(sys.nodes[0]).join('\n')
	for want in ['testers = [0x0E00, 0x0E80]', 'activation_types = [0x00, 0xE1]',
		'general_inactivity_ms = 60000', 'announce_count = 0'] {
		assert sec.contains(want), sec
	}
	assert !sec.contains('initial_inactivity_ms') && !sec.contains('announce_interval_ms'), sec
	// and nothing of it where nothing is declared
	plain := doip_section(doip_system().nodes[0]).join('\n')
	assert !plain.contains('testers') && !plain.contains('_ms'), plain
}

fn test_a_doip_policy_the_entity_cannot_serve_is_refused() {
	cases := {
		'0x0001 is not a tester address':          doipcfg.Policy{
			testers: [i64(0x0001)]
		}
		'lists 0x0E00 twice':                      doipcfg.Policy{
			testers: [i64(0x0E00), 0x0E00]
		}
		'lists 9 addresses':                       doipcfg.Policy{
			testers: []i64{len: 9, init: 0x0E00 + index}
		}
		'`testers` is empty':                      doipcfg.Policy{
			has_testers: true
		}
		'`activation_types` is empty':             doipcfg.Policy{
			has_types: true
		}
		'activation type 0xE0 is not one':         doipcfg.Policy{
			types: [i64(0xE0)]
		}
		'activation type 0x02 is not one':         doipcfg.Policy{
			types: [i64(0x02)]
		}
		'initial <= general':                      doipcfg.Policy{
			ints: {
				'initial_inactivity_ms': i64(20000)
				'general_inactivity_ms': 10000
			}
		}
		'`announce_count` 11':                     doipcfg.Policy{
			ints: {
				'announce_count': i64(11)
			}
		}
		'at most 10000 ms in all':                 doipcfg.Policy{
			ints: {
				'announce_count':       i64(4)
				'announce_interval_ms': 3000
			}
		}
	}
	for want, pol in cases {
		mut sys := doip_system()
		sys.nodes[0].doip_policy = pol
		assert doip_errs(sys).any(it.contains(want)), '${want}: ${doip_errs(sys)}'
	}
	for k, want in {
		'announce_interval_ms': '`announce_interval_ms` must be an integer'
		'testers':              '`testers` must be a list of integers'
	} {
		mut sys := doip_system()
		sys.nodes[0].doip_not_int = [k]
		assert doip_errs(sys).any(it.contains(want)), '${want}: ${doip_errs(sys)}'
	}
}

// parse: the keys land where the lowering reads them, a non-integer is named, a typo is unknown
fn test_the_doip_policy_keys_are_parsed() {
	dir := os.join_path(os.temp_dir(), 'sysgen_doip_policy_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'system.toml'), '
[[node]]
name = "a"
ecu  = "a.toml"
doip = { logical = 0x07A0, testers = [0x0E00], activation_types = [0x00, 0xE1], initial_inactivity_ms = 1000, announce_interval_ms = 2.5, tester = 1 }
') or {
		panic(err)
	}
	sys := sysmodel.parse_system(os.join_path(dir, 'system.toml')) or { panic(err) }
	n := sys.nodes[0]
	assert n.doip_policy.has_testers && n.doip_policy.testers == [i64(0x0E00)]
	assert n.doip_policy.has_types && n.doip_policy.types == [i64(0x00), 0xE1]
	assert n.doip_policy.int_of('initial_inactivity_ms') == 1000
	assert n.doip_policy.int_of('general_inactivity_ms') == 300000 // the default
	assert n.doip_not_int == ['announce_interval_ms']
	assert n.doip_unknown == ['tester']
	// and lowered back as written
	assert doip_section(n).join('\n').contains('testers = [0x0E00]\nactivation_types = [0x00, 0xE1]\ninitial_inactivity_ms = 1000')
}

fn test_two_entities_at_one_logical_address_are_refused() {
	mut sys := doip_system()
	sys.nodes[1].has_doip = true
	sys.nodes[1].has_doip_logical = true
	sys.nodes[1].doip_logical = 0x07A0
	sys.nodes[1].doip_logical_raw = 0x07A0
	assert seg_errs(sys).any(it.contains('doip logical address 0x7a0 shared by "tcu" and "bench"')), seg_errs(sys).str()
}

fn test_a_functional_address_outside_its_range_is_refused() {
	mut sys := doip_system()
	sys.nodes[0].has_doip_functional = true
	sys.nodes[0].doip_functional_raw = 0x07DF
	assert doip_errs(sys).any(it.contains('outside the functional range')), doip_errs(sys).str()
}

fn test_an_unknown_doip_key_is_refused() {
	mut sys := doip_system()
	sys.nodes[0].doip_unknown = ['address']
	assert doip_errs(sys).any(it.contains('doip has unknown key "address"')), doip_errs(sys).str()
}

fn test_doip_needs_the_endpoint_it_answers_at() {
	mut sys := doip_system()
	sys.nodes[0].has_endpoint = false
	sys.nodes[0].endpoint = ''
	assert doip_errs(sys).any(it.contains('declares `doip` but no `endpoint`')), doip_errs(sys).str()
}

// UDP 13400 is DoIP's announcement socket on the node: SOME/IP cannot listen there too.
fn test_a_someip_port_of_13400_beside_doip_is_refused() {
	mut sys := doip_system()
	sys.nodes[0].port = 13400
	sys.nodes[0].port_raw = 13400
	assert doip_errs(sys).any(it.contains('endpoint port 13400 is DoIP')), doip_errs(sys).str()
}

fn test_doip_needs_the_diagnostic_server_it_carries() {
	mut sys := doip_system()
	sys.nodes[0].diag = sysmodel.Diag{}
	assert doip_errs(sys).any(it.contains('has no `diag` allocation')), doip_errs(sys).str()
	sys = doip_system()
	sys.nodes[0].view.isotp_conns = []
	assert doip_errs(sys).any(it.contains('0 [isotp] connection(s)')), doip_errs(sys).str()
	sys = doip_system()
	sys.nodes[0].view.is_threadx = false
	assert doip_errs(sys).any(it.contains('is not a threadx target')), doip_errs(sys).str()
}

// The node's [doip] is the SYSTEM's now: a hand-written one beside the lowered one is a second
// network identity (and two tables of one name).
fn test_an_authored_doip_table_is_refused() {
	mut sys := doip_system()
	sys.nodes[0].view.has_doip = true
	assert seg_errs(sys).any(it.contains('authors bus wiring (a [doip])')), seg_errs(sys).str()
}

// A DoIP-only node — on CAN alone, no segment — may declare an endpoint for it; a SOME/IP port on
// it would be dead configuration.
fn test_a_doip_only_node_may_carry_an_endpoint_without_a_port() {
	mut sys := doip_system()
	sys.buses << sysmodel.Bus{
		name:      'pt'
		kind:      'can'
		interface: 'can0'
	}
	mut n := sys.nodes[0]
	n.name = 'ecu'
	n.buses = ['pt']
	n.has_port = false
	n.port = 0
	n.port_raw = 0
	n.endpoint = '192.168.0.52'
	sys.nodes << n
	sys.nodes[0].has_doip = false
	e := seg_errs(sys).filter(it.contains('"ecu"'))
	assert !e.any(it.contains('endpoint')), e.str()
	assert doip_section(n).len > 0
	sys.nodes[sys.nodes.len - 1].has_port = true
	sys.nodes[sys.nodes.len - 1].port_raw = 30490
	assert seg_errs(sys).any(it.contains('"ecu"') && it.contains('has a `port` but it is on no someip bus')), seg_errs(sys).str()
}

// In a COMPOSED system nothing lowers a [[node]]'s `doip`, so it would look effective and do
// nothing — refused there.
fn test_doip_on_a_composed_node_is_refused() {
	mut sys := doip_system()
	e := sysmodel.validate_system(sys).filter(it.severity == .error).map(it.msg)
	assert e.any(it.contains('`doip` on a [[node]] is lowered by sysgen')), e.str()
}

// One endpoint, one [someip]: a second segment would be lowered into nothing (the gateway path
// kept only the last one it saw).
fn test_a_node_on_two_segments_is_refused() {
	mut sys := gateway_member_system()
	sys.buses << sysmodel.Bus{
		name:        'tel2'
		kind:        'someip'
		service:     0x0200
		has_service: true
		version:     1
		has_version: true
	}
	sys.nodes[2].buses << 'tel2'
	assert seg_errs(sys).any(it.contains('is a member of 2 someip buses')), seg_errs(sys).str()
}

// An RPC is answered to the DEFAULT peer — with several partners that is only the first event's,
// which says nothing about who the client is.
fn test_an_rpc_shell_on_a_member_with_two_partners_is_refused() {
	mut sys := tel_system_of_three()
	sys.nodes[1].view.shell_on = true
	sys.nodes[1].view.shell_bus = 'eth0'
	assert seg_errs(sys).any(it.contains('serves its [shell] over SOME/IP')), seg_errs(sys).str()
	// ...one partner is fine (tcu's shell on the bench tool)
	mut two := tel_system_of_three()
	two.nodes[0].view.shell_on = true
	two.nodes[0].view.shell_bus = 'eth0'
	assert !seg_errs(two).any(it.contains('serves its [shell]')), seg_errs(two).str()
}

// A frame none of whose signals is declared has no producer: that is reported once, as what it
// is, not also as a unicast violation between members that do not read it.
fn test_an_undeclared_event_is_not_also_a_unicast_violation() {
	mut sys := tel_system()
	sys.frames[1].signals = ['Nope']
	assert !seg_errs(sys).any(it.contains('is read by')), seg_errs(sys).str()
}

fn test_a_doip_address_doip_cannot_bring_up_is_refused() {
	for bad in ['192.168.0.1', '192.168.0.255', '192.168.0', '192.168.0.300'] {
		mut sys := doip_system()
		sys.nodes[0].endpoint = bad
		assert doip_errs(sys).any(it.contains('is not a host address DoIP can bring up')), '${bad}: ${doip_errs(sys)}'
	}
}

// A DoIP-only node is on no segment, so the segment's own address check never sees it.
fn test_a_doip_address_another_node_answers_at_is_refused() {
	mut sys := doip_system()
	sys.buses << sysmodel.Bus{
		name:      'pt'
		kind:      'can'
		interface: 'can0'
	}
	mut n := sys.nodes[0]
	n.name = 'ecu'
	n.buses = ['pt']
	n.has_port = false
	n.doip_logical = 0x07B0
	n.doip_logical_raw = 0x07B0
	n.endpoint = '192.168.0.190' // the bench tool's
	sys.nodes << n
	e := seg_errs(sys).filter(it.contains('both answer at'))
	assert e.len == 1 && e[0].contains('"ecu" and "bench"'), e.str()
}

// A composed node authoring a per-event peer: the composed checks see only [someip].peer.
fn test_an_authored_frame_peer_in_a_composed_system_is_refused() {
	mut sys := tel_system()
	sys.nodes[0].view.frame_peer = true
	e := sysmodel.validate_system(sys).filter(it.severity == .error).map(it.msg)
	assert e.any(it.contains('names its own `peer`')), e.str()
}

// The shell's bus is resolved as loom2v resolves it: a [shell] naming no bus rides
// [telemetry].bus, so a node whose telemetry is on eth0 serves RPC there all the same — and the
// multi-partner refusal must see it (codex on #343).
fn test_an_inherited_eth_shell_counts_as_rpc_on_the_segment() {
	doc := toml.parse_text('[telemetry]\nenabled = true\nbus = "eth0"\nid = 0x8100\n\n[shell]\nmethod = 0x0001\n') or {
		panic(err)
	}
	view := sysmodel.parse_node_view(doc)
	assert view.shell_on
	assert view.shell_bus == 'eth0', view.shell_bus
	assert view.shell_bus == ecumodel.module_bus(doc, 'shell')
	mut sys := tel_system_of_three()
	sys.nodes[1].view.shell_on = view.shell_on
	sys.nodes[1].view.shell_bus = view.shell_bus
	assert seg_errs(sys).any(it.contains('serves its [shell] over SOME/IP')), seg_errs(sys).str()
	// ...and an explicit bus still wins over the inherited one
	own := toml.parse_text('[telemetry]\nbus = "eth0"\n\n[shell]\nbus = "can0"\n') or { panic(err) }
	assert ecumodel.module_bus(own, 'shell') == 'can0'
	assert sysmodel.parse_node_view(own).shell_bus == 'can0'
}
