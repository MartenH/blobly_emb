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
	load_errs := sys.load_nodes()
	for e in load_errs {
		eprintln('syscheck: could not load ${e}')
	}

	println('system: ${sys.buses.len} bus(es), ${sys.nodes.len} node(s), ${sys.routes.len} route(s)')
	for b in sys.buses {
		fd := if b.fd { 'FD' } else { 'classic' }
		println('  bus ${b.name}: ${b.interface} ${b.bitrate} ${fd} (${b.dbc})')
	}
	for n in sys.nodes {
		println('  node ${n.name}: nm=0x${n.nm.hex()} trace=${n.trace} buses=${n.buses}')
	}

	issues := sysmodel.validate_system(sys)
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
