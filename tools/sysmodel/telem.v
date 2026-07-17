// sysmodel/telem — telemetry frame ownership (REQ-TOPO-002). A threadx node's
// comm thread transmits its telemetry (CpuLoad + optional detail) as REAL frames
// on the telemetry bus, but those ids live in the node's [telemetry] block, so
// the per-bus single-writer check (which sees only named [[frame]] tx) never
// sees them. Two nodes with the same telemetry id on one bus are an unowned
// multi-writer; a telemetry id equal to a DBC application frame or inside the NM
// peer range aliases two frames on the wire. These use the EFFECTIVE ids loom2v
// emits — an omitted [telemetry].id defaults to 0 and the CpuLoad frame is ALWAYS
// sent, so two id-less nodes both transmit at CAN id 0; the detail frame is sent
// only when detail_id != 0.
module sysmodel

import os
import tools.candb

// TelemId — one telemetry frame id (label + effective value), so the check
// iterates the CpuLoad id and the detail id uniformly.
struct TelemId {
	label string
	id    u32
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
	mut owner := map[string]string{} // "<busname>#<id>" -> "<node> <label>"
	for n in s.nodes {
		// only a threadx node with live telemetry transmits these frames; they ride
		// the telemetry bus (an interface -> its system bus).
		if !n.view.is_threadx || !n.view.has_telemetry {
			continue
		}
		bus := s.bus_by_interface(n.view.telem_bus) or { continue }
		mut mine := map[u32]string{} // this node's own ids (catch id == detail_id)
		mut tframes := [TelemId{'telemetry id', n.view.telem_id}]
		if n.view.telem_detail_id != 0 {
			tframes << TelemId{'telemetry detail_id', n.view.telem_detail_id}
		}
		for tf in tframes {
			label := tf.label
			id := tf.id
			// FDCAN masks id & 0x7ff — a telemetry id above that is truncated on the wire
			if id > 0x7ff {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'node "${n.name}": ${label} 0x${id.hex()} exceeds 0x7ff (11-bit CAN) — the FDCAN backend masks id & 0x7ff'
				}
			}
			if prev := mine[id] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'node "${n.name}": ${label} 0x${id.hex()} collides with its own ${prev}'
				}
			} else {
				mine[id] = label
			}
			key := '${bus.name}#${id}'
			if prev := owner[key] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'bus "${bus.name}": ${label} 0x${id.hex()} of "${n.name}" collides with ${prev} — telemetry frames are single-writer per bus'
				}
			} else {
				owner[key] = '${n.name} ${label}'
			}
			// collision with a DBC application frame on the same bus
			if db := dbs[bus.name] {
				if m := db.lookup(id) {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-002'
						msg:      'node "${n.name}": ${label} 0x${id.hex()} aliases DBC application frame "${m.name}" on bus "${bus.name}"'
					}
				}
			}
			// collision with the node's NM peer range (alive ids) on the same bus
			if n.view.has_nm && n.view.nm_enabled && id >= n.view.peers_lo && id <= n.view.peers_hi {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'node "${n.name}": ${label} 0x${id.hex()} falls in the NM peer range [0x${n.view.peers_lo.hex()},0x${n.view.peers_hi.hex()}] on bus "${bus.name}"'
				}
			}
		}
	}
	return issues
}
