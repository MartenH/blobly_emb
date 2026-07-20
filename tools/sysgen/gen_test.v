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

// REQ-TOPO-004 (codex #164): a gateway's generated [nm], when its primary bus has
// the cluster, pins `bus` to the PRIMARY interface — loom2v would otherwise default
// NM to [telemetry].bus, which on a gateway may be a different (secondary) bus.
fn test_gateway_nm_bound_to_primary_bus() {
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
	assert out.contains('bus   = "can0"'), 'gateway NM pinned to the primary interface:\n${out}'
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
