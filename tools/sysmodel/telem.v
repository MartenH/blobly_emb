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

// ModuleFrame — one generated comm-module CAN frame: the bus interface it rides,
// a human label, its effective CAN id, whether the id came from a DBC-NAME binding
// (a bound endpoint IS that DBC frame, so it must not be flagged as aliasing an
// unrelated application frame), and the binding name if it FAILED to resolve
// (loom2v fails generation for a name with no matching DBC message).
struct ModuleFrame {
	iface      string
	label      string
	id         u32
	bound      bool
	unresolved string // the binding name if it named a DBC message that doesn't exist
}

// resolve_binding maps a module id binding to its CAN id: a name resolves against
// the bus DBC — snake()-normalized the way loom2v matches (record = "trace_record"
// hits a DBC message "TraceRecord") — a numeric passes through. Returns (id, ok);
// ok = false only when a NAME was given but no DBC message matched.
fn resolve_binding(dbs map[string]candb.Database, busname string, id u32, name string) (u32, bool) {
	if name == '' {
		return id, true
	}
	if db := dbs[busname] {
		for m in db.messages {
			if snake(m.name) == snake(name) {
				return m.id, true
			}
		}
	}
	return id, false
}

// module_frame builds a ModuleFrame, resolving an optional DBC-name binding and
// flagging an unresolved name (loom2v would fail generation on it).
fn module_frame(dbs map[string]candb.Database, s System, iface string, label string, id u32, name string) ModuleFrame {
	rid, ok := resolve_binding(dbs, tbus_name(s, iface), id, name)
	return ModuleFrame{iface, label, rid, name != '', if name != '' && !ok { name } else { '' }}
}

// module_frames returns every comm-module tx frame a node emits, each tagged with
// the bus interface it rides. Telemetry + trace run on the host target too; shell
// is the threadx comm thread only. Trace rides [trace].bus (else the telemetry bus).
// trace_generated reports whether loom2v actually emits the trace module for a
// node: always for a threadx target, and for a HOST target only in the
// single-partition shape with no COM bridge (trace_host) — a multi-partition or
// bus-facing host node builds WITHOUT trace, so its trace ids never hit the wire.
// effective_comm_thread: does this node actually get a comm thread at RUNTIME? A
// DISSOLVED node's partial has no bus signals, so parse_node_view leaves
// comm_thread_on = false — but sysgen adds its produced/consumed/route wiring, so a
// threadx node that is external (produces/consumes a system signal OR gateways a
// route) does get one. The reservation scans must see those trace/shell rx ids.
fn effective_comm_thread(n Node, s System) bool {
	return n.view.comm_thread_on || (n.view.is_threadx && node_has_external(s, n))
}

fn trace_generated(n Node, s System) bool {
	if !n.view.trace_on {
		return false
	}
	if n.view.is_threadx {
		// threadx trace runs inside the comm thread (trace_module_init / rx arms /
		// trace_produce_drain are emitted only under comm_thread_on) — a bridgeless
		// threadx node has no comm thread, so no trace frame reaches the wire.
		return effective_comm_thread(n, s)
	}
	host := !n.view.is_baremetal // no target / host runner
	// loom2v's trace_host requires EXACTLY one partition (m.part.by_part.len == 1)
	// and no bridge (COM signal / ISO-TP) and no node-local route — otherwise it
	// warns and builds WITHOUT trace. Zero partitions also gets no trace.
	return host && n.view.partition_count == 1 && !node_has_bus_signal(n) && !n.view.has_isotp
		&& !n.view.has_route
}

// is_trace_host reports the single-partition HOST trace-runner shape: loom2v's
// emit_run_trace_host sends only the inline CpuLoad frame and never emits the
// LoadDetail frame, so a trace-host node's telemetry detail_id is NOT on the wire.
fn is_trace_host(n Node, s System) bool {
	return !n.view.is_threadx && trace_generated(n, s)
}

fn module_frames(n Node, s System, dbs map[string]candb.Database) []ModuleFrame {
	mut out := []ModuleFrame{}
	// [telemetry]: CpuLoad is always sent (effective id, 0 if omitted); detail only
	// when detail_id != 0. (No DBC-name binding — always a numeric/default id.)
	if n.view.has_telemetry && n.view.telem_bus != '' {
		out << ModuleFrame{n.view.telem_bus, 'telemetry id', n.view.telem_id, false, ''}
		// the host trace runner sends inline CpuLoad only — never the detail frame.
		if n.view.telem_detail_id != 0 && !is_trace_host(n, s) {
			out << ModuleFrame{n.view.telem_bus, 'telemetry detail_id', n.view.telem_detail_id, false, ''}
		}
	}
	// [trace]: the TraceModule transmits the record stream AND command responses,
	// on [trace].bus (else the telemetry bus) — only when loom2v actually emits it.
	if trace_generated(n, s) {
		tbus := if n.view.trace_bus != '' { n.view.trace_bus } else { n.view.telem_bus }
		if tbus != '' {
			out << module_frame(dbs, s, tbus, 'trace record id', n.view.trace_record_id,
				n.view.trace_record_name)
			out << module_frame(dbs, s, tbus, 'trace rsp id', n.view.trace_rsp_id,
				n.view.trace_rsp_name)
		}
	}
	// [shell]: the threadx comm thread transmits shell.out responses on the comm
	// (telemetry) channel.
	if effective_comm_thread(n, s) && n.view.shell_on && n.view.telem_bus != '' {
		out << module_frame(dbs, s, n.view.telem_bus, 'shell out id', n.view.shell_out_id,
			n.view.shell_out_name)
	}
	// [[isotp]]: the ISO-TP bridge TRANSMITS responses at tx_id on the isotp bus.
	for c in n.view.isotp_conns {
		if c.iface != '' {
			out << ModuleFrame{c.iface, 'isotp tx id', c.tx_id, false, ''}
		}
	}
	return out
}

// module_rx_frames returns the RECEIVE endpoint ids a node's runtime listens on
// (trace cmd + dump_fc, shell in + fc). Another node TRANSMITTING at one of these
// ids would drive this node's module state, so they are reserved on the bus.
fn module_rx_frames(n Node, s System, dbs map[string]candb.Database) []ModuleFrame {
	mut out := []ModuleFrame{}
	if trace_generated(n, s) {
		tbus := if n.view.trace_bus != '' { n.view.trace_bus } else { n.view.telem_bus }
		if tbus != '' {
			out << module_frame(dbs, s, tbus, 'trace cmd (rx) id', n.view.trace_cmd_id,
				n.view.trace_cmd_name)
			// dump_fc receives ONLY when explicitly bound (loom2v emits its rx arm
			// under dump_fc_bound) — otherwise there is no receiver to reserve.
			if n.view.trace_dump_fc_bound {
				out << module_frame(dbs, s, tbus, 'trace dump_fc (rx) id', n.view.trace_dump_fc_id,
					n.view.trace_dump_fc_name)
			}
		}
	}
	if effective_comm_thread(n, s) && n.view.shell_on && n.view.telem_bus != '' {
		out << module_frame(dbs, s, n.view.telem_bus, 'shell in (rx) id', n.view.shell_in_id,
			n.view.shell_in_name)
		out << module_frame(dbs, s, n.view.telem_bus, 'shell fc (rx) id', n.view.shell_fc_id,
			n.view.shell_fc_name)
	}
	// [[isotp]]: the ISO-TP bridge RECEIVES requests at rx_id on the isotp bus.
	for c in n.view.isotp_conns {
		if c.iface != '' {
			out << ModuleFrame{c.iface, 'isotp rx (rx) id', c.rx_id, false, ''}
		}
	}
	return out
}

// check_bus_dbcs: every DECLARED bus DBC must parse. loom2v loads a DBC lazily
// (only when a feature needs it), so a system with a missing/malformed DBC can
// otherwise pass syscheck when its nodes happen not to touch it — accepting a bus
// whose advertised contract cannot be read (REQ-TOPO-003).
fn check_bus_dbcs(s System) []Issue {
	mut issues := []Issue{}
	for bus in s.buses {
		if bus.dbc == '' {
			continue
		}
		path := if os.is_abs_path(bus.dbc) { bus.dbc } else { os.join_path(s.dir, bus.dbc) }
		candb.load_dbc_file(path) or {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'bus "${bus.name}": cannot load declared DBC "${bus.dbc}": ${err}'
			}
		}
	}
	return issues
}

// message_of_signal returns the DBC message that carries a signal (SG_) — its
// name and on-wire CAN id/format — or none if the signal is in no message.
fn message_of_signal(db candb.Database, signame string) ?candb.Message {
	for m in db.messages {
		for sg in m.signals {
			if sg.name == signame {
				return m
			}
		}
	}
	return none
}

// check_frame_single_writer: each CAN frame on a bus has exactly one transmitting
// node. loom2v emits a frame only when a node PRODUCES a signal that maps to it
// (`tx_by_msg`), NOT merely because a [[frame]] tx-policy block names it — so
// ownership is derived from each node's actual `to = <bus>` signals resolved to
// their DBC messages. Keyed by on-wire CAN ID + format (candb accepts duplicate
// BO_ ids, and two differently-named messages at one id are the SAME wire frame)
// (REQ-TOPO-001).
fn check_frame_single_writer(s System) []Issue {
	mut issues := []Issue{}
	for bus in s.buses {
		if bus.dbc == '' {
			continue // no DBC -> can't resolve signals to messages
		}
		path := if os.is_abs_path(bus.dbc) { bus.dbc } else { os.join_path(s.dir, bus.dbc) }
		db := candb.load_dbc_file(path) or { continue }
		mut owners := map[string][]string{} // "<id>:<ext>" -> distinct node names
		mut label := map[string]string{} // key -> a readable frame name for the message
		for n in s.nodes {
			if bus.name !in n.buses {
				continue
			}
			mut seen := map[string]bool{} // one frame per node even if it writes >1 SG
			for sig in n.view.produces[bus.interface] {
				m := message_of_signal(db, sig) or { continue }
				key := '${m.id}:${m.ext}'
				label[key] = m.name
				if key in seen {
					continue
				}
				seen[key] = true
				owners[key] << n.name
			}
		}
		for key, nodes in owners {
			if nodes.len > 1 {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-001'
					msg:      'bus "${bus.name}": frame "${label[key]}" (CAN id ${key}) transmitted by ${nodes.len} nodes (${nodes.join(', ')}) — one frame owner per bus'
				}
			}
		}
	}
	return issues
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
	// module RECEIVE + TRANSMIT reservations only (NOT alive/app frames): a produced
	// application frame landing on one is misrouted into that module or contends for
	// the id, so those are scanned against this map after ownership is built.
	mut reserved := map[string]string{}
	// SEED every ACTIVE NM node's alive id as a frame owner on its NM bus, so a
	// module frame equal to ANY node's alive id is caught — not only the emitting
	// node's own range. alive-vs-alive uniqueness is check_identity_uniqueness's job.
	for n in s.nodes {
		if n.view.has_nm && n.view.nm_enabled && n.view.has_alive {
			// (if the NM bus doesn't resolve, skip only the alive seed — NOT the rx
			// reservation below, which is independent.)
			if nb := s.bus_by_interface(n.view.nm_bus) {
				key := '${nb.name}#${n.view.alive}'
				if _ := owner[key] {
				} else {
					owner[key] = 'the NM alive id of "${n.name}"'
				}
			}
		}
		// RESERVE each node's module RECEIVE ids: a frame transmitted at one of them
		// is misrouted into the module (seeded, not reported — two listeners on one
		// rx id is not itself a collision).
		for f in module_rx_frames(n, s, dbs) {
			if f.unresolved != '' {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'node "${n.name}": ${f.label} names DBC message "${f.unresolved}" which does not exist on its bus — loom2v fails generation for an unresolved binding'
				}
				continue
			}
			bus := s.bus_by_interface(f.iface) or { continue }
			key := '${bus.name}#${f.id}'
			reserved[key] = '${f.label} of "${n.name}"'
			if _ := owner[key] {
			} else {
				owner[key] = '${f.label} of "${n.name}"'
			}
		}
	}
	for n in s.nodes {
		frames := module_frames(n, s, dbs)
		mut mine := map[string]string{} // this node's own frames (catch id == id)
		for f in frames {
			// a named binding that resolves to no DBC message fails loom2v generation
			if f.unresolved != '' {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'node "${n.name}": ${f.label} names DBC message "${f.unresolved}" which does not exist on its bus — loom2v fails generation for an unresolved binding'
				}
				continue
			}
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
			reserved[key] = 'the ${f.label} of "${n.name}"'
			if prev := owner[key] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'bus "${bus.name}": ${f.label} 0x${f.id.hex()} of "${n.name}" collides with ${prev} — these are single-writer per bus'
				}
			} else {
				owner[key] = 'the ${f.label} of "${n.name}"'
			}
			// collision with a DBC application frame on the same bus — but NOT for a
			// name-bound endpoint, which IS that DBC frame by design (loom2v supports
			// named trace/shell bindings).
			if !f.bound {
				if db := dbs[bus.name] {
					if m := db.lookup(f.id) {
						issues << Issue{
							severity: .error
							req:      'REQ-TOPO-002'
							msg:      'node "${n.name}": ${f.label} 0x${f.id.hex()} aliases DBC application frame "${m.name}" on bus "${bus.name}"'
						}
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
	// a produced DBC application frame must not land on a module RECEIVE/TRANSMIT
	// reservation (trace cmd/dump_fc, shell in/fc, ISO-TP rx, or a module tx like
	// telemetry): the application traffic would be routed into that module's
	// on_cmd/receiver, or contend with a module transmitter, on the same CAN id.
	for n in s.nodes {
		for iface, sigs in n.view.produces {
			bus := s.bus_by_interface(iface) or { continue }
			db := dbs[bus.name] or { continue }
			for sig in sigs {
				m := message_of_signal(db, sig) or { continue }
				key := '${bus.name}#${m.id}'
				if prev := reserved[key] {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-002'
						msg:      'bus "${bus.name}": application frame "${m.name}" 0x${m.id.hex()} produced by "${n.name}" collides with ${prev} — application traffic would be misrouted into that module / contend for the id'
					}
				}
			}
		}
	}
	// application DBC frames must not fall in an ACTIVE NM peer range on their bus:
	// the NM receiver accepts the whole peer range by CAN id, so a transmitted app
	// frame there is misread as an alive frame and can corrupt cluster state.
	for bus in s.buses {
		db := dbs[bus.name] or { continue }
		mut lo := u32(0)
		mut hi := u32(0)
		mut have := false
		// only a DBC message EXPLICITLY bound as [nm].alive is exempt — loom2v emits
		// that message AS the alive frame, so it is not an application frame. A
		// numeric/default alive id does NOT make a same-id app frame legal: both the
		// NM rx arm and the app frame's rx path run for that id, so they collide.
		mut alive_ids := map[u32]bool{}
		for n in s.nodes {
			if n.view.has_nm && n.view.nm_enabled && n.view.nm_bus == bus.interface {
				lo = n.view.peers_lo
				hi = n.view.peers_hi
				have = true
				if n.view.alive_from_binding {
					alive_ids[n.view.alive] = true
				}
			}
		}
		if !have {
			continue
		}
		for m in db.messages {
			if m.id >= lo && m.id <= hi && m.id !in alive_ids {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'bus "${bus.name}": DBC application frame "${m.name}" id 0x${m.id.hex()} falls in the NM peer range [0x${lo.hex()},0x${hi.hex()}] — the NM receiver would misread it as an alive frame'
				}
			}
		}
	}
	// a signal route makes the gateway TRANSMIT the destination DBC frame. If its id
	// equals a module RECEIVE reservation on the destination bus (a trace command,
	// shell input, or ISO-TP rx id), routed traffic is dispatched into that module.
	// A pure dissolved gateway has no authored producer entry for the frame, so it
	// escapes the node scans above — check routes explicitly (REQ-TOPO-002).
	for r in s.routes {
		if r.to == '' {
			continue
		}
		if r.signal != '' {
			tb := s.bus_by_name(r.to) or { continue }
			db := dbs[tb.name] or { continue }
			mut fid := ?u32(none)
			for m in db.messages {
				for sg in m.signals {
					if sg.name == r.signal {
						fid = m.id
						break
					}
				}
			}
			id := fid or { continue }
			key := '${tb.name}#${id}'
			if res := reserved[key] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'route on "${r.gateway}": destination frame for "${r.signal}" (id 0x${id.hex()}) on bus "${r.to}" collides with ${res} — routed traffic would be dispatched into that module'
				}
			}
			continue
		}
		// FRAME route: the raw PDU is opaque — its id must not alias a module rx/tx
		// reservation on EITHER endpoint. On `to`, forwarded traffic would be dispatched
		// into a dest-bus module; on `from`, the received frame would drive the gateway's
		// OWN module (trace cmd / shell in / ISO-TP request). Check both.
		for role, bn in {
			'destination': r.to
			'source':      r.from
		} {
			b := s.bus_by_name(bn) or { continue }
			db := dbs[b.name] or { continue }
			mut fid := ?u32(none)
			for m in db.messages {
				if m.name == r.frame {
					fid = m.id
					break
				}
			}
			id := fid or { continue }
			if res := reserved['${b.name}#${id}'] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'frame route on "${r.gateway}": forwarded frame "${r.frame}" (id 0x${id.hex()}) collides with ${res} on the ${role} bus "${bn}" — the raw PDU would be dispatched into that module'
				}
			}
		}
	}
	return issues
}
