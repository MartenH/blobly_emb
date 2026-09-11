// syscheck — the SYSTEM-level validator CLI (docs/multi-node.md). Parses a
// system.toml, loads each node's ecu.toml, and runs the cross-node checks
// (single-writer per bus, identity uniqueness, NM cluster coherence, routes).
// Errors exit non-zero — the build gate for a system of ECUs, the way ecucheck
// gates one node.
//
//   v run tools/syscheck examples/system_bench/system.toml
module main

import os
import sysmodel

fn main() {
	if os.args.len < 2 {
		eprintln('usage: syscheck <system.toml>')
		exit(2)
	}
	path := os.args[1]
	mut sys := sysmodel.parse_system(path) or {
		eprintln('syscheck: ${err}')
		exit(2)
	}
	// two authoring models (docs/multi-node.md): DISSOLUTION — the system declares
	// cross-node [[signal]]s and/or [[route]]s and nodes are partial (internals only),
	// gated once generated; or COMPOSED — nodes are complete ecu.tomls that hand-author
	// their bus signals. A system-scope [[signal]] OR a [[route]] (both need sysgen to
	// lower them) picks the dissolution model — a pure frame-route firewall has routes
	// but no cross-node signals.
	// frames too: a system.toml carrying only [[frame]]s is still the DISSOLVED model, and the
	// composed validator never looks at System.frames — it would report OK for an event nothing
	// carries (codex on #245).
	// ...and an ENDPOINT: a member's address and port are system-owned identity that only the
	// dissolution lowers, so an RPC-only segment — endpoints, no signals or frames — is
	// dissolved too; read as composed, its internals-only ECU files look like incomplete
	// configs (codex on #245).
	//
	// The CARRIER KIND is deliberately NOT a trigger. A composed system declares its buses in
	// system.toml as well, someip ones included, and authors the wiring in complete per-node ECU
	// files — so selecting on `kind == "someip"` forced dissolution on it and then rejected its
	// authored [bus]/[someip]/signals as forbidden wiring. Every composed someip system would
	// have stopped validating (codex on #279). What marks the DISSOLVED model is the presence of
	// system-owned artifacts, never the kind of carrier the system happens to name.
	mut someip_owned := false
	for n in sys.nodes {
		if n.has_endpoint {
			someip_owned = true
		}
	}
	dissolved := sys.signals.len > 0 || sys.routes.len > 0 || sys.frames.len > 0 || someip_owned
	load_errs := if dissolved { sys.load_nodes_partial() } else { sys.load_nodes() }
	for e in load_errs {
		eprintln('syscheck: could not load ${e}')
	}

	mode := if dissolved { 'dissolution' } else { 'composed' }
	println('system (${mode}): ${sys.buses.len} bus(es), ${sys.nodes.len} node(s), ${sys.signals.len} signal(s), ${sys.routes.len} route(s)')
	for b in sys.buses {
		fd := if b.fd { 'FD' } else { 'classic' }
		println('  bus ${b.name}: ${b.interface} ${b.bitrate} ${fd} (${b.dbc})')
	}
	for n in sys.nodes {
		nm := if n.has_nm_alloc { '0x' + n.nm.hex() } else { '- (not an NM node)' }
		println('  node ${n.name}: nm=${nm} trace=${n.trace} buses=${n.buses}')
	}

	issues := if dissolved { sysmodel.validate_system_gen(sys) } else { sysmodel.validate_system(sys) }
	mut nerr := 0
	mut nwarn := 0
	for iss in issues {
		match iss.severity {
			.error {
				eprintln('  ERROR [${iss.req}] ${iss.msg}')
				nerr++
			}
			.warning {
				eprintln('  warn  [${iss.req}] ${iss.msg}')
				nwarn++
			}
		}
	}

	if load_errs.len > 0 {
		nerr += load_errs.len
	}

	// LOWER IT AND GATE THE RESULT. The model checks above only see what system.toml says;
	// half the contract is what the lowered node config MEANS, and every rule about that is
	// owned by ecucheck and loom2v. Restating those here builds a second, partial copy that
	// drifts -- so syscheck runs the real sysgen instead, and a clean syscheck means the
	// nodes actually generate (#277, the #245 rounds 4-6 family). Skipped when the model is
	// already broken: lowering an inconsistent system reports the same faults a second time,
	// in the generator's words.
	if dissolved && nerr == 0 {
		// A private, unpredictable, atomically-created directory — see
		// sysmodel.private_temp_dir for why a PID-derived name is not safe on a shared /tmp.
		tmp := sysmodel.private_temp_dir('syscheck_lower') or {
			eprintln('syscheck: ${err}')
			exit(1)
		}
		gerrs := sysmodel.sysgen_errors(path, tmp)
		// Cleaned up HERE, not in a defer: both exits below go through exit(), which does not
		// unwind deferred blocks, so a deferred rmdir never ran and every run left a tree of
		// generated configs and copied DBCs behind (codex on #279).
		os.rmdir_all(tmp) or {}
		for e in gerrs {
			eprintln('  ERROR [REQ-TOPO-005] lowered: ${e}')
			nerr++
		}
	}

	if nerr == 0 {
		println('syscheck: OK (${nwarn} warning(s))')
		exit(0)
	}
	eprintln('syscheck: ${nerr} error(s), ${nwarn} warning(s)')
	exit(1)
}
