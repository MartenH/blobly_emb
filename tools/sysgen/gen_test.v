module main

import os
import sysmodel

// @verifies REQ-TOPO-005

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
