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
	dissolved := sys.signals.len > 0 || sys.routes.len > 0
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
		if n.external {
			println('  node ${n.name}: external (off-system) buses=${n.buses} consumes=${n.consumes}')
			continue
		}
		println('  node ${n.name}: nm=0x${n.nm.hex()} trace=${n.trace} buses=${n.buses}')
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
	if nerr == 0 {
		println('syscheck: OK (${nwarn} warning(s))')
		exit(0)
	}
	eprintln('syscheck: ${nerr} error(s), ${nwarn} warning(s)')
	exit(1)
}
