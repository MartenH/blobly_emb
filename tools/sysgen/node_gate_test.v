module main

import os
import sysmodel

// @verifies REQ-TOPO-005

// #351: the system gate runs the node gate (loom2v, on the DBC the node build gives it) for EVERY
// node — a dissolved multi-bus gateway included, which it used to skip as "validated by the node
// build". Each case below is a node rule loom2v refuses and the system gate once accepted for
// system_full's gateway; each must now be refused by sysgen with loom2v's own words.

const full_dir = os.join_path(@VMODROOT, 'examples', 'system_full')

// stage copies system_full's configuration (system.toml, its DBCs, every node's ecu.toml) into a
// private tree, so a case can edit the gateway's ecu.toml without touching the example.
fn stage(tag string) string {
	dir := sysmodel.private_temp_dir('sysgen_gate_${tag}') or { panic(err) }
	for f in os.ls(full_dir) or { panic(err) } {
		if f == 'system.toml' || f.ends_with('.dbc') {
			os.cp(os.join_path(full_dir, f), os.join_path(dir, f)) or { panic(err) }
		}
	}
	for n in os.ls(os.join_path(full_dir, 'nodes')) or { panic(err) } {
		src := os.join_path(full_dir, 'nodes', n, 'ecu.toml')
		if os.is_file(src) {
			os.mkdir_all(os.join_path(dir, 'nodes', n)) or { panic(err) }
			os.cp(src, os.join_path(dir, 'nodes', n, 'ecu.toml')) or { panic(err) }
		}
	}
	return dir
}

fn edit_gateway(dir string, old string, new string) {
	p := os.join_path(dir, 'nodes', 'sysnode', 'ecu.toml')
	text := os.read_file(p) or { panic(err) }
	assert text.contains(old), 'fixture drifted: sysnode ecu.toml no longer contains ${old}'
	os.write_file(p, text.replace(old, new)) or { panic(err) }
}

// gate lowers the gateway and runs sysgen's node gate on it — the same call main() makes.
fn gate(dir string) []string {
	mut sys := sysmodel.parse_system(os.join_path(dir, 'system.toml')) or { panic(err) }
	errs := sys.load_nodes_partial()
	assert errs.len == 0, errs.str()
	node := sys.nodes.filter(it.name == 'sysnode')[0]
	assert node.buses.len > 1 && !sys.is_someip_leaf(node), 'sysnode is no longer a multi-bus gateway'
	text := generate_node(sys, node) or { panic(err) }
	gen_path := os.join_path(dir, 'gen-sysnode.toml')
	os.write_file(gen_path, text) or { panic(err) }
	return loom2v_gate(sys, node, gen_path, dir) or { panic(err) }
}

struct GateCase {
	what string
	old  string
	new  string
	want string // a fragment of loom2v's own refusal
}

fn test_gateway_node_rules_reach_the_system_gate() {
	base := stage('base')
	defer {
		os.rmdir_all(base) or {}
	}
	clean := gate(base)
	assert clean.len == 0, 'system_full sysnode must pass the node gate as committed: ${clean}'

	row_11 := '"0x11" = { sessions = ["extended"], security = 1 }'
	did_w := 'write = { session = ["extended"], security = 1 }'
	cases := [
		GateCase{'gated service only in safety', row_11, '"0x11" = { sessions = ["safety"], security = 1 }', 'services 0x11 needs security 1 but is not allowed in the extended session'},
		GateCase{'gated service with no 0x27 row', '"0x27" = {}', '', 'services leaves out 0x27'},
		GateCase{'DID write level differs from the 0x2E row', '"0x2E" = {}', '"0x2E" = { security = 2 }', 'one unlock cannot satisfy both'},
		GateCase{'unknown security_key name', 'security_key      = "reference"', 'security_key      = "referenc"', 'security_key "referenc"'},
		GateCase{'service level out of range', row_11, '"0x11" = { sessions = ["extended"], security = 9 }', 'security 9 is not a 0x27 level'},
		GateCase{'DID write level out of range', did_w, 'write = { session = ["extended"], security = 9 }', 'security 9 is not a 0x27 level'},
		GateCase{'writable DID with no gate behind an ungated 0x2E', did_w, 'write = { session = ["extended"] }', 'writable from the network with no security level'},
	]
	for i, c in cases {
		errs := gate_case(i, c)
		assert errs.any(it.contains(c.want)), '${c.what}: the system gate must refuse with loom2v\'s "${c.want}", got ${errs}'
	}
}

fn gate_case(i int, c GateCase) []string {
	dir := stage('case${i}')
	defer {
		os.rmdir_all(dir) or {}
	}
	edit_gateway(dir, c.old, c.new)
	return gate(dir)
}

// The merge the gate runs must be the merge the node build runs: every gateway Makefile's
// dbcmerge inputs are the DBCs gateway_dbcs names, in its order (dbcmerge keeps the first name
// of a shared frame, so the order is part of the contract).
fn test_gateway_makefiles_merge_what_the_gate_merges() {
	mut seen := 0
	// os.ls, not os.glob: V's glob folds a repeated path step (CI checks out to .../blobly_emb/blobly_emb)
	for ex in os.ls(os.join_path(@VMODROOT, 'examples')) or { panic(err) } {
		sys_path := os.join_path(@VMODROOT, 'examples', ex, 'system.toml')
		if !os.is_file(sys_path) {
			continue
		}
		mut sys := sysmodel.parse_system(sys_path) or { panic(err) }
		errs := sys.load_nodes_partial()
		assert errs.len == 0, errs.str()
		rel := os.dir(sys_path).all_after(@VMODROOT + os.path_separator)
		for n in sys.nodes {
			if n.buses.len < 2 || sys.is_someip_leaf(n) {
				continue
			}
			mk := os.join_path(os.dir(sys_path), os.dir(n.ecu), 'Makefile')
			text := os.read_file(mk) or { panic('gateway ${n.name}: ${err}') }
			line := text.split_into_lines().filter(it.contains('tools/dbcmerge/gen.v'))
			assert line.len == 1, '${mk}: expected one dbcmerge step'
			// `... dbcmerge/gen.v <out> <in>...`, inputs relative to the repo root
			ins := line[0].all_after('tools/dbcmerge/gen.v').fields()[1..]
			want := (gateway_dbcs(sys, n) or { panic(err) }).map('${rel}/${it}')
			assert ins == want, '${mk}: merges ${ins}, the system gate merges ${want}'
			seen++
		}
	}
	assert seen >= 3, 'expected the three gateway examples, found ${seen}'
}

// End to end: the sysgen binary — what syscheck shells — refuses a gateway rule only loom2v states.
fn test_sysgen_refuses_a_gateway_node_rule() {
	dir := stage('e2e')
	defer {
		os.rmdir_all(dir) or {}
	}
	edit_gateway(dir, '"0x11" = { sessions = ["extended"], security = 1 }', '"0x11" = { sessions = ["safety"], security = 1 }')
	out := os.join_path(dir, 'out')
	errs := sysmodel.sysgen_errors(os.join_path(dir, 'system.toml'), out)
	assert errs.any(it.contains('sysnode') && it.contains('loom2v') && it.contains('not allowed in the extended session')), 'sysgen must refuse the gateway: ${errs}'
}

// A gateway whose DBCs the node build's merge refuses is refused here by the same tool.
fn test_gateway_dbc_merge_refusal_reaches_the_system_gate() {
	dir := stage('merge')
	defer {
		os.rmdir_all(dir) or {}
	}
	// a frame both DBCs define under one id but differently: dbcmerge refuses the pair
	for f in ['compute.dbc', 'edge.dbc'] {
		p := os.join_path(dir, f)
		text := os.read_file(p) or { panic(err) }
		dlc := if f == 'compute.dbc' { 8 } else { 4 }
		os.write_file(p, text + '\nBO_ 1911 Clash_${f.all_before('.')}: ${dlc} Vector__XXX\n SG_ Clash : 0|8@1+ (1,0) [0|0] "" Vector__XXX\n') or {
			panic(err)
		}
	}
	errs := gate(dir)
	assert errs.any(it.starts_with('dbcmerge:')), 'a merge refusal must surface as a system-gate error: ${errs}'
}

// Whatever makes loom2v fail is a system-gate error, its own wording or not.
fn test_loom2v_failure_is_never_clean() {
	dir := sysmodel.private_temp_dir('sysgen_gate_panic') or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	p := os.join_path(dir, 'gen-x.toml')
	os.write_file(p, '[uds\n') or { panic(err) }
	errs := sysmodel.loom2v_errors(p, '')
	assert errs.len > 0, 'an unparsable config must not pass the node gate'
	assert !errs.any(it.contains('generation failed')), 'the panic text is kept: ${errs}'
}
