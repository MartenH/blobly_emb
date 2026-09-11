module main

import os
import rand
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

// ...but a ROUTER is still refused. Routing between CAN and SOME/IP needs a translating bridge,
// and generate_gateway_node emits every bus in the CAN/DBC shape with no [someip] at all — so
// the membership would be dropped on the floor.
fn test_a_route_gateway_that_is_also_a_someip_member_is_refused() {
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
	assert seg_errs(sys).any(it.contains('is a route gateway AND a member of someip bus')), seg_errs(sys).str()
}

// ...and so is a member carrying SEVERAL CAN buses: that is a multi-DBC gateway.
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
	assert seg_errs(sys).any(it.contains('sits on 2 CAN buses')), seg_errs(sys).str()
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
