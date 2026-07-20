// sysgen — the SYSTEM generator (multi-node P1b, docs/multi-node.md). The
// "dissolution": a cross-node signal is authored ONCE in system.toml (name,
// fields, producer, bus, DBC frame); each node authors only its INTERNALS
// (partitions/threads/FBs with reads/writes by signal name). sysgen merges them
// into a COMPLETE ecu.toml per node — the derived [bus]/[[signal]]/[[frame]] bus
// wiring + the generated [nm] identity, prepended to the authored internals —
// which then feeds the existing ecucheck/loom2v unchanged.
//
//   v run tools/sysgen examples/system_bench/system.toml
//
// Generated files land in <node-dir>/gen-ecu.toml. The generator NEVER edits the
// authored node or the DBC (the DBC is the hand-authored wire contract).
module main

import os
import toml
import sysmodel
import tools.candb

fn main() {
	if os.args.len < 2 {
		eprintln('usage: sysgen <system.toml>')
		exit(2)
	}
	path := os.args[1]
	mut sys := sysmodel.parse_system(path) or {
		eprintln('sysgen: ${err}')
		exit(2)
	}
	// validate BEFORE generating — never emit wiring for an inconsistent system
	// (the same cross-node checks syscheck runs; a bad system is not buildable).
	load_errs := sys.load_nodes_partial()
	mut had_err := false
	for e in load_errs {
		eprintln('sysgen: ${e}')
		had_err = true
	}
	issues := sysmodel.validate_system_gen(sys)
	for iss in issues {
		if iss.severity == .error {
			eprintln('sysgen: ERROR [${iss.req}] ${iss.msg}')
			had_err = true
		}
	}
	if had_err {
		eprintln('sysgen: refusing to generate an inconsistent system')
		exit(1)
	}

	for n in sys.nodes {
		out := generate_node(sys, n) or {
			eprintln('sysgen: node "${n.name}": ${err}')
			exit(1)
		}
		// generated files live beside system.toml, so [import] dbc resolves the
		// same as the bus's dbc path (relative to the system dir).
		gen_path := os.join_path(sys.dir, 'gen-${n.name}.toml')
		os.write_file(gen_path, out) or {
			eprintln('sysgen: write ${gen_path}: ${err}')
			exit(1)
		}
		// gate the GENERATED node (partials never pass alone — the guarantee is
		// that what sysgen EMITS is buildable). ecucheck is the SCHEMA gate;
		// loom2v is the TARGET gate — it enforces the comm-thread bridge
		// constraints ecucheck can't see (a threadx external signal must be a
		// trivial u32 LE @ bit0, a standard id, cyclic, no E2E/SecOC), so a clean
		// verdict means the node actually generates, not just parses.
		gerrs := sysmodel.ecucheck_errors(gen_path)
		if gerrs.len > 0 {
			for e in gerrs {
				eprintln('sysgen: generated ${n.name}: ${e}')
			}
			exit(1)
		}
		// defer the loom2v TARGET gate ONLY for the nodes P2c will handle: a multi-bus
		// GATEWAY (speaks >1 DBC, route form not consumed by loom2v yet) and a THREADX
		// node on a non-index-0 bus (the FDCAN Rx-ISR glue serves index 0 today). A
		// HOST / bare-metal node on a secondary bus is STILL gated — loom2v's
		// non-threadx checks (e.g. bare-metal external signals) must not be masked, and
		// the host emitter already handles multiple buses (docs/multi-node.md, P2c).
		bus := node_bus(sys, n) or {
			eprintln('sysgen: node "${n.name}": ${err}')
			exit(1)
		}
		if n.buses.len > 1 || (n.view.is_threadx && bus.interface != 'can0') {
			tag := if n.buses.len > 1 { 'gateway' } else { 'threadx non-can0 node' }
			println('sysgen: ${n.name} -> ${gen_path} (ok, ${tag} — loom2v target gate deferred to P2c)')
			continue
		}
		dbc_path := if os.is_abs_path(bus.dbc) { bus.dbc } else { os.join_path(sys.dir, bus.dbc) }
		lerrs := sysmodel.loom2v_errors(gen_path, dbc_path)
		if lerrs.len > 0 {
			for e in lerrs {
				eprintln('sysgen: generated ${n.name}: loom2v: ${e}')
			}
			exit(1)
		}
		println('sysgen: ${n.name} -> ${gen_path} (ok)')
	}
	println('sysgen: ${sys.nodes.len} node(s) generated + gated')
}

// generate_node emits the complete ecu.toml text for one node: the derived
// system-facing preamble + the node's authored internals verbatim (last, so its
// [[fb.handler]] nested tables never precede another section — the V TOML
// nested-parse trap, vlang/v#27684).
fn generate_node(sys sysmodel.System, node sysmodel.Node) !string {
	node_path := if os.is_abs_path(node.ecu) { node.ecu } else { os.join_path(sys.dir, node.ecu) }
	authored := os.read_file(node_path) or { return error('read ${node_path}: ${err}') }
	doc := toml.parse_file(node_path) or { return error('parse ${node_path}: ${err}') }
	view := sysmodel.parse_node_view(doc)

	// which local partition owns each signal (the FB that reads/writes it lives
	// in a thread that lives in a partition) — the [[signal]] from/to endpoint.
	sig_part := signal_partitions(doc)

	// a GATEWAY (multi-bus) node lowers differently: one [bus.*] per bus (each
	// with its own DBC) + the resolved [[route]]s (P2, docs/multi-node.md).
	if node.buses.len > 1 {
		return generate_gateway_node(sys, node, authored)
	}

	// the node sits on one bus in P1 — the bus carrying its signals.
	bus := node_bus(sys, node) or { return err }

	mut b := []string{}
	b << '# GENERATED by tools/sysgen from system.toml — DO NOT EDIT.'
	b << '# Node "${node.name}": authored internals + system-owned wiring/identity.'
	b << ''
	if bus.dbc != '' {
		b << '[import]'
		b << 'dbc = "${bus.dbc}"'
		b << ''
	}
	b << '[bus.${bus.interface}]'
	b << 'interface = "${bus.interface}"'
	b << 'fd        = ${bus.fd}'
	b << 'core      = 0'
	b << ''
	// identity, allocated by system.toml (REQ-TOPO-005): node id from [[node]],
	// alive = the cluster's peers base + node, peers + timing from [bus.*.nm].
	b << '[nm]'
	b << 'node  = 0x${node.nm.hex()}'
	if bus.has_nm_cluster {
		b << 'alive = 0x${(bus.nm_peers_lo + node.nm).hex()}'
		b << 'peers = [0x${bus.nm_peers_lo.hex()}, 0x${bus.nm_peers_hi.hex()}]'
		if bus.nm_msg_cycle_ms > 0 {
			b << 'msg_cycle_ms = ${bus.nm_msg_cycle_ms}'
		}
		if bus.nm_timeout_ms > 0 {
			b << 'timeout_ms = ${bus.nm_timeout_ms}'
		}
		if bus.nm_repeat_ms > 0 {
			b << 'repeat_ms = ${bus.nm_repeat_ms}'
		}
		if bus.nm_wait_sleep_ms > 0 {
			b << 'wait_sleep_ms = ${bus.nm_wait_sleep_ms}'
		}
	} else {
		// no [bus.*.nm] cluster declared -> NM must NOT run. loom2v defaults an
		// [nm] with scalar keys (like `node`) to enabled = true with its default
		// peer range 0x500..0x53f, so without this the node would transmit
		// unvalidated default NM (syscheck skips NM checks when has_nm_cluster is
		// false). Disable it explicitly.
		b << 'enabled = false'
	}
	b << ''

	// produced signals (this node is the SysSignal.producer): tx on the bus.
	mut emitted_frames := map[string]bool{}
	for sig in sys.signals {
		if sig.producer != node.name {
			continue
		}
		part := sig_part[sig.name] or { return error('signal "${sig.name}" is produced here but no FB writes it') }
		b << '[[signal]]'
		b << 'name   = "${sig.name}"'
		b << 'fields = ${fields_inline(sig.fields)}'
		b << 'from   = "${part}"'
		b << 'to     = "${bus.interface}"'
		b << ''
		// one [[frame]] per PDU: several signals may share a DBC message, but its
		// tx cadence is configured once (validated to agree in check_signals_dissolved).
		if sig.frame != '' && sig.frame !in emitted_frames {
			emitted_frames[sig.frame] = true
			cyc := sysmodel.effective_cycle_ms(sig.cycle_ms)
			b << '  [[frame]]'
			b << '  name = "${sig.frame}"'
			b << '  bus  = "${bus.interface}"'
			b << '  tx   = { mode = "cyclic", cycle_ms = ${cyc} } # trailing comment terminates the nested [[frame]] parse (vlang/v#27684)'
			b << ''
		}
	}
	// consumed signals (an FB here reads a signal ANOTHER node produces): rx.
	// dedup repeated reads — two handlers reading one signal is a single rx port.
	mut rx_seen := map[string]bool{}
	for name in view.fb_reads {
		if name in rx_seen {
			continue
		}
		rx_seen[name] = true
		sig := sys.signal_by_name(name) or { continue }
		if sig.producer == node.name {
			continue // locally produced (or self-loop) — not a bus rx
		}
		part := sig_part[name] or { continue }
		b << '[[signal]]'
		b << 'name   = "${sig.name}"'
		b << 'fields = ${fields_inline(sig.fields)}'
		b << 'from   = "${bus.interface}"'
		b << 'to     = "${part}"'
		b << ''
	}

	// the authored internals, verbatim and LAST.
	b << '# --- authored internals (${os.file_name(node_path)}) ---'
	b << authored.trim_space()
	b << ''
	return b.join('\n')
}

// generate_gateway_node emits a multi-bus GATEWAY node (P2, docs/multi-node.md):
// one [bus.*] per bus (each carrying its own DBC — a gateway speaks >1 contract),
// the [nm] scoped to the primary bus (a per-bus-NM gateway is a later P2 item),
// any signals it itself produces/consumes, then the RESOLVED [[route]]s (source ->
// destination interface + the concrete src/dst DBC frames). Its authored internals
// come last, as always.
fn generate_gateway_node(sys sysmodel.System, node sysmodel.Node, authored string) !string {
	mut b := []string{}
	b << '# GENERATED by tools/sysgen from system.toml — DO NOT EDIT.'
	b << '# Node "${node.name}": GATEWAY — multi-bus wiring + resolved routes + internals.'
	b << ''
	// one [bus.*] per bus, each with its own dbc (loom2v P2c consumes per-bus DBCs).
	for bn in node.buses {
		bus := sys.bus_by_name(bn) or { return error('bus "${bn}" not declared') }
		b << '[bus.${bus.interface}]'
		b << 'interface = "${bus.interface}"'
		b << 'fd        = ${bus.fd}'
		b << 'core      = 0'
		if bus.dbc != '' {
			b << 'dbc       = "${bus.dbc}"'
		}
		b << ''
	}
	// identity: NM scoped to the PRIMARY bus buses[0] (multi-instance NM across a
	// gateway's clusters is a later P2 item — docs/multi-node.md).
	prim := sys.bus_by_name(node.buses[0]) or { return error('primary bus not declared') }
	b << '[nm]'
	b << 'node  = 0x${node.nm.hex()}'
	if prim.has_nm_cluster {
		// NM runs INSIDE the comm thread, on the telemetry bus — [nm].bus only labels
		// the manifest, it does not move the tx (checks.v). So the gateway's telemetry
		// bus MUST equal its primary NM bus; that is enforced in check_dissolved_nodes,
		// and here we simply emit the cluster (no misleading [nm].bus).
		b << 'alive = 0x${(prim.nm_peers_lo + node.nm).hex()}'
		b << 'peers = [0x${prim.nm_peers_lo.hex()}, 0x${prim.nm_peers_hi.hex()}]'
		if prim.nm_msg_cycle_ms > 0 {
			b << 'msg_cycle_ms = ${prim.nm_msg_cycle_ms}'
		}
		if prim.nm_timeout_ms > 0 {
			b << 'timeout_ms = ${prim.nm_timeout_ms}'
		}
		if prim.nm_repeat_ms > 0 {
			b << 'repeat_ms = ${prim.nm_repeat_ms}'
		}
		if prim.nm_wait_sleep_ms > 0 {
			b << 'wait_sleep_ms = ${prim.nm_wait_sleep_ms}'
		}
	} else {
		b << 'enabled = false'
	}
	b << ''
	// the resolved routes this gateway carries.
	for r in sys.routes {
		if r.gateway != node.name {
			continue
		}
		if r.signal == '' {
			continue // frame routes are P2b — not lowered yet
		}
		b << lower_signal_route(sys, r)!
	}
	b << '# --- authored internals (${os.file_name(node.ecu)}) ---'
	b << authored.trim_space()
	b << ''
	return b.join('\n')
}

// lower_signal_route resolves a SIGNAL [[route]] to concrete interfaces + the DBC
// frames that carry the signal on each bus (source per from.dbc, destination per
// to.dbc). A signal absent from either DBC is a generation error — the decode /
// re-encode has no frame (REQ-TOPO-008/-003).
fn lower_signal_route(sys sysmodel.System, r sysmodel.Route) ![]string {
	from := sys.bus_by_name(r.from) or { return error('route: bus "${r.from}" not declared') }
	to := sys.bus_by_name(r.to) or { return error('route: bus "${r.to}" not declared') }
	src_frame := frame_of_signal(sys, from, r.signal) or {
		return error('route signal "${r.signal}": ${err}')
	}
	dst_frame := frame_of_signal(sys, to, r.signal) or {
		return error('route signal "${r.signal}": ${err}')
	}
	// the nested-table [[route]] form loom2v/ecucheck already parse (from = { bus,
	// frame }, to = { bus, frame }), extended with the top-level `signal` that marks
	// it a translating route (decode `src_frame` on `from`, re-encode `dst_frame` on `to`).
	mut out := []string{}
	out << '[[route]] # GENERATED — resolved interfaces + src/dst DBC frames'
	out << 'signal = "${r.signal}"'
	out << 'from = { bus = "${from.interface}", frame = "${src_frame}" }'
	out << 'to   = { bus = "${to.interface}", frame = "${dst_frame}" }'
	out << ''
	return out
}

// frame_of_signal returns the DBC message name that carries `sig` on `bus` (the
// bus's DBC must define it as an SG_ in EXACTLY ONE message). Errors if the bus has
// no DBC, no such SG_, or the signal appears in more than one frame — an ambiguous
// mapping would silently lower the route to the wrong CAN id / cadence.
fn frame_of_signal(sys sysmodel.System, bus sysmodel.Bus, sig string) !string {
	if bus.dbc == '' {
		return error('bus "${bus.name}" has no DBC to resolve the frame')
	}
	path := if os.is_abs_path(bus.dbc) { bus.dbc } else { os.join_path(sys.dir, bus.dbc) }
	db := candb.load_dbc_file(path) or { return error('load DBC "${bus.dbc}": ${err}') }
	mut hits := []string{}
	for m in db.messages {
		for s in m.signals {
			if s.name == sig {
				hits << m.name
				break
			}
		}
	}
	if hits.len == 0 {
		return error('not defined in bus "${bus.name}" DBC "${bus.dbc}"')
	}
	if hits.len > 1 {
		return error('appears in ${hits.len} frames (${hits.join(', ')}) in bus "${bus.name}" DBC "${bus.dbc}" — the route mapping is ambiguous')
	}
	return hits[0]
}

// signal_partitions maps each signal a node's FBs read/write to the partition
// that owns the handling FB (fb -> thread -> partition).
fn signal_partitions(doc toml.Doc) map[string]string {
	// thread name -> partition name
	mut thread_part := map[string]string{}
	for p in (doc.value_opt('partition') or { toml.Any([]toml.Any{}) }).array() {
		pm := p.as_map()
		pname := (pm['name'] or { toml.Any('') }).string()
		for t in (pm['thread'] or { toml.Any([]toml.Any{}) }).array() {
			tname := (t.as_map()['name'] or { toml.Any('') }).string()
			if tname != '' {
				thread_part[tname] = pname
			}
		}
	}
	mut out := map[string]string{}
	for fb in (doc.value_opt('fb') or { toml.Any([]toml.Any{}) }).array() {
		fm := fb.as_map()
		thr := (fm['thread'] or { toml.Any('') }).string()
		part := thread_part[thr] or { '' }
		if part == '' {
			continue
		}
		for h in (fm['handler'] or { toml.Any([]toml.Any{}) }).array() {
			hm := h.as_map()
			for r in (hm['reads'] or { toml.Any([]toml.Any{}) }).array() {
				out[r.string()] = part
			}
			for w in (hm['writes'] or { toml.Any([]toml.Any{}) }).array() {
				out[w.string()] = part
			}
		}
	}
	return out
}

// fields_inline renders a { name = "type", … } TOML inline table deterministically
// (sorted keys, so regeneration is byte-stable).
fn fields_inline(fields map[string]string) string {
	mut keys := fields.keys()
	keys.sort()
	mut parts := []string{}
	for k in keys {
		parts << '${k} = "${fields[k]}"'
	}
	return '{ ${parts.join(", ")} }'
}

// node_bus returns the single system bus a P1 node sits on (its signals ride it).
fn node_bus(sys sysmodel.System, node sysmodel.Node) !sysmodel.Bus {
	if node.buses.len == 0 {
		return error('node is on no bus')
	}
	return sys.bus_by_name(node.buses[0]) or { error('bus "${node.buses[0]}" not declared') }
}

