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
				has_endpoint: true
			},
			sysmodel.Node{
				name:         'bench'
				ecu:          'nodes/bench/ecu.toml'
				buses:        ['tel']
				endpoint:     '192.168.0.190'
				port:         30491
				has_endpoint: true
			},
		]
		signals: [
			sysmodel.SysSignal{
				name:     'BenchLoad'
				producer: 'tcu'
				bus:      'tel'
				fields:   {
					'load': 'u8'
				}
			},
			sysmodel.SysSignal{
				name:     'LampCmd'
				producer: 'bench'
				bus:      'tel'
				fields:   {
					'level': 'u8'
				}
			},
		]
		frames:  [
			sysmodel.SysFrame{
				name:        'BenchTelem'
				bus:         'tel'
				id:          0x8001
				has_id:      true
				signals:     ['BenchLoad']
				tx_mode:     'cyclic'
				cycle_ms:    300
				has_e2e:     true
				e2e_data_id: 0x21
				e2e_counter: 7
				e2e_crc:     8
			},
			sysmodel.SysFrame{
				name:    'BenchCmd'
				bus:     'tel'
				id:      0x8010
				has_id:  true
				signals: ['LampCmd']
			},
		]
	}
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

// An event is received WHOLE: a node reading ONE signal of a two-signal event still declares
// both, or the payload offsets would shift under it.
fn test_a_subscriber_declares_every_signal_of_the_event_it_reads() {
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
		fb_reads: ['BenchLoad'] // reads ONE of the two
	}
	out := generate_someip_node(sys, sys.nodes[1], sys.buses[0], view, {
		'BenchLoad':  'bench'
		'BenchTicks': 'bench'
		'LampCmd':    'bench'
	}, '') or { panic(err) }
	assert out.contains('name   = "BenchLoad"')
	assert out.contains('name   = "BenchTicks"'), 'the unread half of the event was dropped:\n${out}'
}
