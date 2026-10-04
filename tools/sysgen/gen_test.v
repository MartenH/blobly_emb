module main

import os
import sysmodel

// @verifies REQ-TOPO-005, REQ-TOPO-006

// REQ-TOPO-006: a multi-bus GATEWAY node lowers to one [bus.*] per bus (each with
// its own DBC) plus the RESOLVED signal route — from/to interfaces and the concrete
// src/dst DBC frames the routed signal lives in on each bus.
fn test_gateway_lowering() {
	dir := os.join_path(os.temp_dir(), 'sysgen_gw_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""\nBU_: dom gw\nBO_ 288 SpeedFrame: 8 dom\n SG_ Speed : 0|32@1+ (1,0) [0|0] "" gw\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'edge.dbc'), 'VERSION ""\nBU_: gw zone\nBO_ 512 Speed_E: 8 gw\n SG_ Speed : 0|32@1+ (1,0) [0|0] "" zone\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'gw.toml'), '
[target]
kind    = "threadx"
tick_ms = 1
[telemetry]
enabled = true
bus     = "can0"
id      = 0x7E0
') or { panic(err) }
	sys := sysmodel.System{
		dir:   dir
		buses: [
			sysmodel.Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'compute.dbc'
			},
			sysmodel.Bus{
				name:      'edge'
				interface: 'can1'
				dbc:       'edge.dbc'
			},
		]
		nodes: [sysmodel.Node{
			name:         'gw'
			ecu:          'gw.toml'
			buses:        ['compute', 'edge']
			nm:           0x11
			has_nm_alloc: true
		}]
		routes: [sysmodel.Route{
			gateway: 'gw'
			signal:  'Speed'
			from:    'compute'
			to:      'edge'
		}]
	}
	out := generate_node(sys, sys.nodes[0]) or { panic(err) }
	assert out.contains('[bus.can0]') && out.contains('[bus.can1]'), 'one [bus.*] per bus:\n${out}'
	assert out.contains('dbc       = "compute.dbc"') && out.contains('dbc       = "edge.dbc"'), 'per-bus dbc:\n${out}'
	// the resolved route: source frame per compute.dbc, dest frame per edge.dbc.
	assert out.contains('signal = "Speed"'), 'route signal:\n${out}'
	assert out.contains('from = { bus = "can0", frame = "SpeedFrame" }'), 'resolved src frame:\n${out}'
	assert out.contains('to   = { bus = "can1", frame = "Speed_E" }'), 'resolved dst frame:\n${out}'
}

// REQ-TOPO-006 (codex #164): a routed signal in MORE THAN ONE destination frame is
// ambiguous — lowering could pick the wrong CAN id/cadence, so it's a hard error.
fn test_gateway_route_ambiguous_dst_frame() {
	dir := os.join_path(os.temp_dir(), 'sysgen_gwamb_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""\nBU_: dom gw\nBO_ 288 SpeedFrame: 8 dom\n SG_ Speed : 0|32@1+ (1,0) [0|0] "" gw\n') or {
		panic(err)
	}
	// edge DBC has Speed in TWO frames -> ambiguous
	os.write_file(os.join_path(dir, 'edge.dbc'), 'VERSION ""\nBU_: gw zone\nBO_ 512 Speed_A: 8 gw\n SG_ Speed : 0|32@1+ (1,0) [0|0] "" zone\nBO_ 513 Speed_B: 8 gw\n SG_ Speed : 0|32@1+ (1,0) [0|0] "" zone\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'gw.toml'), '[target]\nkind = "threadx"\ntick_ms = 1\n') or {
		panic(err)
	}
	sys := sysmodel.System{
		dir:   dir
		buses: [
			sysmodel.Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'compute.dbc'
			},
			sysmodel.Bus{
				name:      'edge'
				interface: 'can1'
				dbc:       'edge.dbc'
			},
		]
		nodes: [sysmodel.Node{
			name:         'gw'
			ecu:          'gw.toml'
			buses:        ['compute', 'edge']
			nm:           0x11
			has_nm_alloc: true
		}]
		routes: [sysmodel.Route{
			gateway: 'gw'
			signal:  'Speed'
			from:    'compute'
			to:      'edge'
		}]
	}
	if _ := generate_node(sys, sys.nodes[0]) {
		assert false, 'an ambiguous destination frame must be a generation error'
	}
}

// REQ-TOPO-004 (codex #164 r7): a gateway's generated [nm] emits the cluster
// (alive + peers) but NO misleading `bus =` line — [nm].bus only labels the
// manifest, it does not move NM's tx (NM runs on the telemetry bus). That
// telemetry-bus == primary-bus requirement is enforced in validation instead.
fn test_gateway_nm_no_misleading_bus_line() {
	dir := os.join_path(os.temp_dir(), 'sysgen_gwnm_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""\nBU_: dom gw\nBO_ 288 SpeedFrame: 8 dom\n SG_ Speed : 0|32@1+ (1,0) [0|0] "" gw\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'edge.dbc'), 'VERSION ""\nBU_: gw zone\nBO_ 512 Speed_E: 8 gw\n SG_ Speed : 0|32@1+ (1,0) [0|0] "" zone\n') or {
		panic(err)
	}
	// telemetry on the SECONDARY bus (can1) — NM must still pin to primary (can0)
	os.write_file(os.join_path(dir, 'gw.toml'), '[target]\nkind = "threadx"\ntick_ms = 1\n[telemetry]\nenabled = true\nbus = "can1"\nid = 0x7E0\n') or {
		panic(err)
	}
	sys := sysmodel.System{
		dir:   dir
		buses: [
			sysmodel.Bus{
				name:           'compute'
				interface:      'can0'
				dbc:            'compute.dbc'
				has_nm_cluster: true
				nm_peers_lo:    0x500
				nm_peers_hi:    0x53f
			},
			sysmodel.Bus{
				name:      'edge'
				interface: 'can1'
				dbc:       'edge.dbc'
			},
		]
		nodes: [sysmodel.Node{
			name:         'gw'
			ecu:          'gw.toml'
			buses:        ['compute', 'edge']
			nm:           0x11
			has_nm_alloc: true
		}]
		routes: [sysmodel.Route{
			gateway: 'gw'
			signal:  'Speed'
			from:    'compute'
			to:      'edge'
		}]
	}
	out := generate_node(sys, sys.nodes[0]) or { panic(err) }
	assert out.contains('alive = 0x511') && out.contains('peers = [0x500, 0x53f]'), 'gateway NM cluster emitted:\n${out}'
	assert !out.contains('bus   = "can0"'), 'no misleading [nm].bus line:\n${out}'
}

// REQ-TOPO-006: a routed signal absent from the destination DBC is a generation
// error — the re-encode has no frame.
fn test_gateway_route_signal_not_in_dst_dbc() {
	dir := os.join_path(os.temp_dir(), 'sysgen_gwbad_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""\nBU_: dom gw\nBO_ 288 SpeedFrame: 8 dom\n SG_ Speed : 0|32@1+ (1,0) [0|0] "" gw\n') or {
		panic(err)
	}
	// edge DBC has NO Speed signal
	os.write_file(os.join_path(dir, 'edge.dbc'), 'VERSION ""\nBU_: gw zone\nBO_ 512 Other_E: 8 gw\n SG_ Other : 0|32@1+ (1,0) [0|0] "" zone\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'gw.toml'), '[target]\nkind = "threadx"\ntick_ms = 1\n') or {
		panic(err)
	}
	sys := sysmodel.System{
		dir:   dir
		buses: [
			sysmodel.Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'compute.dbc'
			},
			sysmodel.Bus{
				name:      'edge'
				interface: 'can1'
				dbc:       'edge.dbc'
			},
		]
		nodes: [sysmodel.Node{
			name:         'gw'
			ecu:          'gw.toml'
			buses:        ['compute', 'edge']
			nm:           0x11
			has_nm_alloc: true
		}]
		routes: [sysmodel.Route{
			gateway: 'gw'
			signal:  'Speed'
			from:    'compute'
			to:      'edge'
		}]
	}
	if _ := generate_node(sys, sys.nodes[0]) {
		assert false, 'a routed signal not in the destination DBC must be a generation error'
	}
}

// codex #142 round 9: a bus without a declared [bus.*.nm] cluster must NOT emit
// an enabled [nm] — loom2v defaults a scalar-key [nm] to enabled = true with its
// default peer range, which syscheck's NM checks (gated on has_nm_cluster) never
// validate. sysgen must disable NM explicitly for such a bus.
fn test_generated_nm_disabled_without_cluster() {
	dir := os.join_path(os.temp_dir(), 'sysgen_nocluster_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'n.toml'), '
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "t" # trailing comment (vlang/v#27684)
[target]
kind    = "threadx"
tick_ms = 1
[telemetry]
enabled = true
bus     = "can0"
id      = 0x7E0
') or { panic(err) }
	sys := sysmodel.System{
		dir:   dir
		buses: [sysmodel.Bus{
			name:      'compute'
			interface: 'can0'
		}] // no nm cluster on this bus
		nodes: [sysmodel.Node{
			name:         'n'
			ecu:          'n.toml'
			buses:        ['compute']
			nm:           0x11
			has_nm_alloc: true
		}]
	}
	out := generate_node(sys, sys.nodes[0]) or { panic(err) }
	assert out.contains('enabled = false'), 'a bus without an NM cluster must disable NM:\n${out}'
	assert !out.contains('peers ='), 'no cluster -> no peers range emitted:\n${out}'
}

// the inverse: a bus WITH a cluster emits the enabled NM (alive + peers), never
// the disabling line.
fn test_generated_nm_enabled_with_cluster() {
	dir := os.join_path(os.temp_dir(), 'sysgen_cluster_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'n.toml'), '
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "t" # trailing comment (vlang/v#27684)
[target]
kind    = "threadx"
tick_ms = 1
[telemetry]
enabled = true
bus     = "can0"
id      = 0x7E0
') or { panic(err) }
	sys := sysmodel.System{
		dir:   dir
		buses: [sysmodel.Bus{
			name:           'compute'
			interface:      'can0'
			has_nm_cluster: true
			nm_peers_lo:    0x500
			nm_peers_hi:    0x53f
		}]
		nodes: [sysmodel.Node{
			name:         'n'
			ecu:          'n.toml'
			buses:        ['compute']
			nm:           0x11
			has_nm_alloc: true
		}]
	}
	out := generate_node(sys, sys.nodes[0]) or { panic(err) }
	assert out.contains('peers = [0x500, 0x53f]'), 'a cluster bus emits the peer range:\n${out}'
	assert !out.contains('enabled = false'), 'a cluster bus must not disable NM:\n${out}'
}

// REQ-COM-008, REQ-E2E-002: a CAN receiver of a frame its bus's DBC declares E2E-protected gets the
// bridge's receive status and lost count on the lowered signal, as a someip E2E receiver does —
// loom2v refuses a received E2E frame whose signals carry no status, so without this a system could
// not declare one. An unprotected frame's receiver gets the value alone.
fn test_a_can_receiver_of_an_e2e_frame_gets_its_status() {
	dir := os.join_path(os.temp_dir(), 'sysgen_rxe2e_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'edge.dbc'), 'VERSION ""\nBU_: src zone\n' +
		'BO_ 296 CmdFrame: 8 src\n SG_ Cmd : 0|16@1+ (1,0) [0|1000] "" zone\n SG_ CmdCrc : 16|8@1+ (1,0) [0|255] "" zone\n SG_ CmdCtr : 24|4@1+ (1,0) [0|15] "" zone\n' +
		'BO_ 297 PlainFrame: 8 src\n SG_ Plain : 0|32@1+ (1,0) [0|0] "" zone\n' +
		'BA_DEF_ BO_ "E2ECounterSignal" STRING;\nBA_DEF_ BO_ "E2ECrcSignal" STRING;\nBA_DEF_ BO_ "E2EProfile" STRING;\nBA_DEF_ BO_ "E2EDataId" INT 0 65535;\nBA_DEF_ BO_ "E2ETimeout" INT 0 65535;\n' +
		'BA_ "E2ECounterSignal" BO_ 296 "CmdCtr";\nBA_ "E2ECrcSignal" BO_ 296 "CmdCrc";\nBA_ "E2EProfile" BO_ 296 "P01";\nBA_ "E2EDataId" BO_ 296 85;\nBA_ "E2ETimeout" BO_ 296 300;\n') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'zone.toml'), '
[[partition]]
name = "front"
core = 0

  [[partition.thread]]
  name = "t"

[[fb]]
name   = "Mon"
thread = "t"

  [[fb.handler]]
  name      = "on_50ms"
  period_ms = 50
  reads     = ["Cmd", "Plain"] # trailing comment terminates the nested block (vlang/v#27684)
') or {
		panic(err)
	}
	sys := sysmodel.System{
		dir:     dir
		buses:   [sysmodel.Bus{
			name:      'edge'
			interface: 'can1'
			dbc:       'edge.dbc'
		}]
		nodes:   [sysmodel.Node{
			name:  'zone'
			ecu:   'zone.toml'
			buses: ['edge']
		}]
		signals: [sysmodel.SysSignal{
			name:     'Cmd'
			fields:   {
				'level': 'u16'
			}
			producer: 'src'
			bus:      'edge'
			frame:    'CmdFrame'
		}, sysmodel.SysSignal{
			name:     'Plain'
			fields:   {
				'v': 'u32'
			}
			producer: 'src'
			bus:      'edge'
			frame:    'PlainFrame'
		}]
	}
	out := generate_node(sys, sys.nodes[0]) or { panic(err) }
	cmd := out.all_after('name   = "Cmd"').all_before('[[')
	assert cmd.contains('status = "RxStatus"') && cmd.contains('lost = "u32"'), out
	assert cmd.contains('level = "u16"'), out
	plain := out.all_after('name   = "Plain"').all_before('[[')
	assert !plain.contains('RxStatus') && !plain.contains('lost'), out
}
