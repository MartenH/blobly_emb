module main

import tools.sysmodel

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
				e2e_data_id:     0x21
				e2e_data_id_raw: 0x21
				e2e_counter:     7
				e2e_crc:         8
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
	assert out.contains('e2e     = { data_id = 0x21, counter_pos = 7, crc_pos = 8 }')
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

// ...and so is a third member, which would leave at least one node deaf: peers are pairwise.
fn test_a_third_member_is_refused() {
	mut sys := tel_system()
	sys.nodes << sysmodel.Node{
		name:         'extra'
		buses:        ['tel']
		endpoint:     '192.168.0.60'
		port:         30492
		has_endpoint: true
	}
	e := sysmodel.validate_system_gen(sys).filter(it.severity == .error).map(it.msg)
	assert e.any(it.contains('has 3 member(s)')), e.str()
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
	assert seg_errs(sys).any(it.contains('does not fit the SOME/IP header')), seg_errs(sys).str()
}

fn test_an_out_of_range_endpoint_port_is_refused() {
	mut sys := tel_system()
	sys.nodes[0].port_raw = 70000
	assert seg_errs(sys).any(it.contains("does not fit a UDP port")), seg_errs(sys).str()
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
