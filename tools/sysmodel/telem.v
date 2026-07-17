// sysmodel/telem — comm-module frame ownership (REQ-TOPO-002). A node's generated
// runtime transmits several REAL CAN frames whose ids live in module blocks, not
// in a [[frame]] the per-bus single-writer check sees: [telemetry] CpuLoad +
// detail, the [trace] TraceModule record + command response, and the [shell]
// response. Two nodes emitting the same id on one bus are an unowned multi-writer;
// an id equal to a DBC application frame or an NM alive id aliases two frames on
// the wire. These use the EFFECTIVE ids loom2v emits (an omitted [telemetry].id
// defaults to 0 and CpuLoad is ALWAYS sent; trace record/rsp default 0x7e5/0x7e3;
// shell out defaults 0x7f1) — and loom2v spawns telemetry/trace on the HOST target
// too, so this is NOT restricted to threadx.
module sysmodel

import os
import tools.candb

// ModuleFrame — one generated comm-module tx frame: the bus interface it rides,
// a human label, and its effective CAN id.
struct ModuleFrame {
	iface string
	label string
	id    u32
}

// resolve_binding maps a module id binding to its numeric CAN id: a name resolves
// against the given bus DBC (else falls back to `id`), a numeric passes through.
fn resolve_binding(dbs map[string]candb.Database, busname string, id u32, name string) u32 {
	if name == '' {
		return id
	}
	if db := dbs[busname] {
		for m in db.messages {
			if m.name == name {
				return m.id
			}
		}
	}
	return id
}

// module_frames returns every comm-module tx frame a node emits, each tagged with
// the bus interface it rides. Telemetry + trace run on the host target too; shell
// is the threadx comm thread only. Trace rides [trace].bus (else the telemetry bus).
fn module_frames(n Node, s System, dbs map[string]candb.Database) []ModuleFrame {
	mut out := []ModuleFrame{}
	// [telemetry]: CpuLoad is always sent (effective id, 0 if omitted); detail only
	// when detail_id != 0.
	if n.view.has_telemetry && n.view.telem_bus != '' {
		out << ModuleFrame{n.view.telem_bus, 'telemetry id', n.view.telem_id}
		if n.view.telem_detail_id != 0 {
			out << ModuleFrame{n.view.telem_bus, 'telemetry detail_id', n.view.telem_detail_id}
		}
	}
	// [trace]: the TraceModule transmits the record stream AND command responses.
	// The trace bus is [trace].bus, else the telemetry bus (a host runner can trace
	// with telemetry disabled, so this is independent of has_telemetry).
	if n.view.trace_on {
		tbus := if n.view.trace_bus != '' { n.view.trace_bus } else { n.view.telem_bus }
		if tbus != '' {
			out << ModuleFrame{tbus, 'trace record id', resolve_binding(dbs, tbus_name(s, tbus),
				n.view.trace_record_id, n.view.trace_record_name)}
			out << ModuleFrame{tbus, 'trace rsp id', resolve_binding(dbs, tbus_name(s, tbus),
				n.view.trace_rsp_id, n.view.trace_rsp_name)}
		}
	}
	// [shell]: the threadx comm thread transmits shell.out responses on the comm
	// (telemetry) channel.
	if n.view.is_threadx && n.view.shell_on && n.view.telem_bus != '' {
		out << ModuleFrame{n.view.telem_bus, 'shell out id', resolve_binding(dbs, tbus_name(s,
			n.view.telem_bus), n.view.shell_out_id, n.view.shell_out_name)}
	}
	return out
}

// tbus_name maps a bus INTERFACE to its system bus name (for the DBC map), or
// returns the interface unchanged when no system bus declares it.
fn tbus_name(s System, iface string) string {
	if b := s.bus_by_interface(iface) {
		return b.name
	}
	return iface
}

fn check_telemetry_frames(s System) []Issue {
	mut issues := []Issue{}
	mut dbs := map[string]candb.Database{}
	for bus in s.buses {
		if bus.dbc == '' {
			continue
		}
		path := if os.is_abs_path(bus.dbc) { bus.dbc } else { os.join_path(s.dir, bus.dbc) }
		dbs[bus.name] = candb.load_dbc_file(path) or { continue } // load errors already reported
	}
	mut owner := map[string]string{} // "<busname>#<id>" -> a phrase naming the owner
	// SEED every ACTIVE NM node's alive id as a frame owner on its NM bus, so a
	// module frame equal to ANY node's alive id is caught — not only the emitting
	// node's own range. alive-vs-alive uniqueness is check_identity_uniqueness's job.
	for n in s.nodes {
		if n.view.has_nm && n.view.nm_enabled && n.view.has_alive {
			nb := s.bus_by_interface(n.view.nm_bus) or { continue }
			key := '${nb.name}#${n.view.alive}'
			if _ := owner[key] {
			} else {
				owner[key] = 'the NM alive id of "${n.name}"'
			}
		}
	}
	for n in s.nodes {
		frames := module_frames(n, s, dbs)
		mut mine := map[string]string{} // this node's own frames (catch id == id)
		for f in frames {
			bus := s.bus_by_interface(f.iface) or { continue }
			key := '${bus.name}#${f.id}'
			// FDCAN masks id & 0x7ff — an id above that is truncated on the wire
			if f.id > 0x7ff {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'node "${n.name}": ${f.label} 0x${f.id.hex()} exceeds 0x7ff (11-bit CAN) — the FDCAN backend masks id & 0x7ff'
				}
			}
			if prev := mine[key] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'node "${n.name}": ${f.label} 0x${f.id.hex()} collides with its own ${prev} on bus "${bus.name}"'
				}
				continue // already reported this node's id; don't double-count in owner
			}
			mine[key] = f.label
			if prev := owner[key] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'bus "${bus.name}": ${f.label} 0x${f.id.hex()} of "${n.name}" collides with ${prev} — these are single-writer per bus'
				}
			} else {
				owner[key] = 'the ${f.label} of "${n.name}"'
			}
			// collision with a DBC application frame on the same bus
			if db := dbs[bus.name] {
				if m := db.lookup(f.id) {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-002'
						msg:      'node "${n.name}": ${f.label} 0x${f.id.hex()} aliases DBC application frame "${m.name}" on bus "${bus.name}"'
					}
				}
			}
			// collision with the node's own NM peer range, when the frame rides its NM bus
			if n.view.has_nm && n.view.nm_enabled && f.iface == n.view.nm_bus
				&& f.id >= n.view.peers_lo && f.id <= n.view.peers_hi {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'node "${n.name}": ${f.label} 0x${f.id.hex()} falls in the NM peer range [0x${n.view.peers_lo.hex()},0x${n.view.peers_hi.hex()}] on bus "${bus.name}"'
				}
			}
		}
	}
	return issues
}
