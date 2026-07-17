// sysmodel — the SYSTEM view over a set of nodes (docs/multi-node.md). Where
// ecumodel validates one ecu.toml, sysmodel composes many: it parses a
// `system.toml` (buses + their DBCs, nodes and which buses each sits on, node
// identities, cross-bus routes), loads each node's ecu.toml, and extracts what
// the system-level checks need — per-bus producers/consumers and each node's
// identities. The checks themselves live in checks.v; syscheck is the CLI.
//
// The extraction is deliberately thin: a `[[signal]]` whose `to` is a bus is a
// producer on that bus, whose `from` is a bus is a consumer — the same
// endpoint model the single-node generator already uses (docs/multi-node.md
// "the transport ladder"). A node's local bus name is matched to a system bus
// by that bus's `interface` (the H735's `[bus.can0]` == system `[bus.compute]`
// when compute.interface == "can0").
module sysmodel

import os
import toml

// Bus — one CAN segment with its own contract. `name` is the system-scope key
// ([bus.compute]); `interface` is the SocketCAN/driver name a node's ecu.toml
// spells locally ("can0"); `dbc` is that segment's frame contract.
pub struct Bus {
pub mut:
	name      string
	interface string
	fd        bool
	bitrate   int
	dbc       string
	// the NM cluster on this bus (dissolution: the identity source the generator
	// stamps into each node's [nm]). peers = the alive-id range; the timings are
	// the shared sleep/wake config. 0/absent = the module defaults.
	nm_peers_lo      u32
	nm_peers_hi      u32
	has_nm_cluster   bool
	nm_msg_cycle_ms  int
	nm_timeout_ms    int
	nm_repeat_ms     int
	nm_wait_sleep_ms int
}

// Diag — a node's ISO-TP diagnostic/boot address pair (how the OTA master
// reaches this node's UDS session). 0 = unset.
pub struct Diag {
pub mut:
	req u32
	rsp u32
}

// Node — one ECU. `ecu` points at its authored ecu.toml (internals); `buses`
// names the system buses it sits on; the identities are allocated at system
// scope and cross-checked for collisions.
pub struct Node {
pub mut:
	name         string
	ecu          string // path to the node's ecu.toml, relative to system.toml
	buses        []string
	nm           u32  // NM node id allocated by system.toml (node id 0 is valid)
	has_nm_alloc bool // whether [[node]] declared `nm` at all (0 != absent)
	diag         Diag
	trace        int
	// --- extracted from the node's ecu.toml (filled by load_node) ---
	view NodeView
}

// SysSignal — a cross-node signal declared ONCE at system scope (the full
// dissolution, docs/multi-node.md): its name, fields, the node that PRODUCES it,
// the bus it rides, and the AUTHORED DBC frame it maps to (no wire format is
// ever invented). The generator emits `to = <bus>` into the producer and
// `from = <bus>` into every node whose FB reads it.
pub struct SysSignal {
pub mut:
	name     string
	fields   map[string]string // field name -> type ("u16", …), the [[signal]].fields table
	producer string            // the node name that transmits it
	bus      string            // the system bus name it rides
	frame    string            // the authored DBC frame it maps to
	cycle_ms int               // the producer's tx cadence (0 = event/default)
}

// Route — a cross-bus forward on a gateway node. Exactly one of `frame`
// (raw-PDU, 1:1) or `signal` (decode-re-encode across differing DBCs) is set.
pub struct Route {
pub mut:
	gateway string
	frame   string
	signal  string
	from    string // source bus name
	to      string // dest bus name
}

// NodeView — the system-relevant slice of a node's ecu.toml: what it produces
// and consumes on each bus (by the node's LOCAL bus interface name), plus its
// NM cluster range. Keyed by the node's local bus name (== a system bus
// interface).
pub struct NodeView {
pub mut:
	// interface -> signal names the node transmits on / receives from that bus
	produces map[string][]string
	consumes map[string][]string
	// interface -> frame names the node transmits on that bus (for frame routes
	// / frame-level single-writer)
	tx_frames  map[string][]string
	nm_node    u32 // the node's own [nm] node id (checked against system.toml's)
	has_nm_node bool // whether [nm].node was declared (node id 0 is valid, 0..255)
	alive      u32 // the node's [nm] alive id (the on-wire id, within peers)
	has_alive  bool // whether [nm].alive was declared (alive = 0 is a valid CAN id)
	peers_lo   u32
	peers_hi   u32
	has_nm     bool
	// the node's FULL per-node gate result (tools/ecucheck: unknown keys, wrong
	// types, structural rules) — a system can't be clean if a node can't build.
	config_errors []string
	// NM sleep/wake timing (0 = defaulted/unset). The cluster must agree on
	// these or its state machines transition at incompatible times (REQ-TOPO-004).
	nm_msg_cycle_ms  int
	nm_timeout_ms    int
	nm_repeat_ms     int
	nm_wait_sleep_ms int
	local_buses []string // the [bus.X] names declared in the node's ecu.toml
	// FB intent (the authored dissolution model): the signal names this node's
	// handlers read / write, by name. The generator derives tx/rx from these +
	// each SysSignal's producer; a signal it writes that it doesn't produce, or
	// reads with no system declaration, is a cross-node bug.
	fb_reads  []string
	fb_writes []string
	// signal name -> the distinct partitions whose FBs read it. A cross-node RX
	// signal read from >1 partition = concurrent readers of one SPSC IOC channel.
	read_partitions map[string][]string
	// a dissolved partial is INTERNALS-ONLY: it must declare NO [[signal]],
	// [[frame]], [bus] or [nm] (the system owns all wiring). These flag ANY such
	// section, even a [[signal]] with a bus endpoint but no matching [bus.*]
	// (which produces/consumes above would miss).
	authored_signals bool
	authored_frames  bool
	authored_routes  bool // a [[route]] in a partial (appended verbatim, uncheckable)
	// the generated [nm] only has a runtime on the threadx target with telemetry
	// (loom2v injects NM there only), so a dissolved node with a cluster must be
	// threadx + have a [telemetry] bus, or its NM is generated but dead.
	is_threadx    bool
	has_telemetry bool
	// the telemetry frames the threadx comm thread transmits on the telemetry bus
	// (CpuLoad + its detail). These are REAL tx ids on the wire, so they must be
	// unique across nodes and not collide with a DBC application frame (REQ-TOPO-002).
	has_telem_id    bool
	telem_id        u32
	has_telem_det   bool
	telem_detail_id u32
}

// System — the whole parsed system.toml plus each node's loaded view.
pub struct System {
pub mut:
	buses   []Bus
	nodes   []Node
	signals []SysSignal // cross-node signals declared at system scope (dissolution)
	routes  []Route
	dir     string // directory of system.toml (node/dbc paths resolve against it)
}

// signal_by_name returns the system signal with the given name, or none.
pub fn (s System) signal_by_name(name string) ?SysSignal {
	for sig in s.signals {
		if sig.name == name {
			return sig
		}
	}
	return none
}

fn m_str(m map[string]toml.Any, key string) string {
	return (m[key] or { toml.Any('') }).string()
}

fn m_int(m map[string]toml.Any, key string) int {
	return int((m[key] or { toml.Any(0) }).int())
}

fn m_u32(m map[string]toml.Any, key string) u32 {
	return u32((m[key] or { toml.Any(0) }).int())
}

fn m_bool(m map[string]toml.Any, key string) bool {
	return (m[key] or { toml.Any(false) }).bool()
}

// parse_system reads a system.toml into a System (nodes not yet loaded — call
// load_nodes for that). Returns an error only on a malformed/absent file; a
// structurally-wrong-but-parseable system is caught by the checks, not here.
pub fn parse_system(path string) !System {
	doc := toml.parse_file(path) or { return error('sysmodel: parse ${path}: ${err}') }
	mut sys := System{
		dir: os.dir(path)
	}
	// [bus.<name>] — a table of tables keyed by name
	if bv := doc.value_opt('bus') {
		for name, cfg in bv.as_map() {
			m := cfg.as_map()
			mut bus := Bus{
				name:      name
				interface: m_str(m, 'interface')
				fd:        m_bool(m, 'fd')
				bitrate:   m_int(m, 'bitrate')
				dbc:       m_str(m, 'dbc')
			}
			// [bus.<name>.nm] — the cluster's NM config (peers range + timing)
			if nmv := m['nm'] {
				nm := nmv.as_map()
				bus.has_nm_cluster = true
				bus.nm_msg_cycle_ms = m_int(nm, 'msg_cycle_ms')
				bus.nm_timeout_ms = m_int(nm, 'timeout_ms')
				bus.nm_repeat_ms = m_int(nm, 'repeat_ms')
				bus.nm_wait_sleep_ms = m_int(nm, 'wait_sleep_ms')
				peers := (nm['peers'] or { toml.Any([]toml.Any{}) }).array()
				if peers.len == 2 {
					bus.nm_peers_lo = u32(peers[0].int())
					bus.nm_peers_hi = u32(peers[1].int())
				}
			}
			sys.buses << bus
		}
	}
	// [[node]]
	if nv := doc.value_opt('node') {
		for n in nv.array() {
			m := n.as_map()
			mut node := Node{
				name:         m_str(m, 'name')
				ecu:          m_str(m, 'ecu')
				nm:           m_u32(m, 'nm')
				has_nm_alloc: 'nm' in m
				trace:        m_int(m, 'trace')
			}
			for b in (m['buses'] or { toml.Any([]toml.Any{}) }).array() {
				node.buses << b.string()
			}
			if dm := m['diag'] {
				d := dm.as_map()
				node.diag = Diag{
					req: m_u32(d, 'req')
					rsp: m_u32(d, 'rsp')
				}
			}
			sys.nodes << node
		}
	}
	// [[signal]] — cross-node signals at system scope (the dissolution)
	if sv := doc.value_opt('signal') {
		for sg in sv.array() {
			m := sg.as_map()
			mut sig := SysSignal{
				name:     m_str(m, 'name')
				producer: m_str(m, 'producer')
				bus:      m_str(m, 'bus')
				frame:    m_str(m, 'frame')
				cycle_ms: m_int(m, 'cycle_ms')
			}
			if fm := m['fields'] {
				for fname, ftype in fm.as_map() {
					sig.fields[fname] = ftype.string()
				}
			}
			sys.signals << sig
		}
	}
	// [[route]]
	if rv := doc.value_opt('route') {
		for r in rv.array() {
			m := r.as_map()
			sys.routes << Route{
				gateway: m_str(m, 'gateway')
				frame:   m_str(m, 'frame')
				signal:  m_str(m, 'signal')
				from:    m_str(m, 'from')
				to:      m_str(m, 'to')
			}
		}
	}
	return sys
}

// bus_by_name returns the Bus with the given system name, or none.
pub fn (s System) bus_by_name(name string) ?Bus {
	for b in s.buses {
		if b.name == name {
			return b
		}
	}
	return none
}

// bus_by_interface returns the Bus with the given interface (== a node's local
// bus name), or none. Interfaces are unique (check_topology_wellformed enforces
// it) so the first match is unambiguous.
pub fn (s System) bus_by_interface(iface string) ?Bus {
	for b in s.buses {
		if b.interface == iface {
			return b
		}
	}
	return none
}

// load_nodes fills each node's NodeView from its ecu.toml. Returns the list of
// nodes it could NOT load (missing/malformed ecu.toml) as error strings, so the
// caller reports them without aborting the rest of the system view.
pub fn (mut s System) load_nodes() []string {
	mut errs := []string{}
	for i in 0 .. s.nodes.len {
		// node paths resolve against system.toml's dir, unless already absolute
		path := if os.is_abs_path(s.nodes[i].ecu) {
			s.nodes[i].ecu
		} else {
			os.join_path(s.dir, s.nodes[i].ecu)
		}
		view := load_node(path) or {
			errs << 'node "${s.nodes[i].name}": ${err}'
			continue
		}
		s.nodes[i].view = view
	}
	return errs
}

// load_nodes_partial fills each node's NodeView by PURE parse (no per-node
// ecucheck) — the dissolution generator's loader: an authored partial node
// (internals only) is not a complete ecu.toml, so the gate belongs on the
// GENERATED output, not the partial.
pub fn (mut s System) load_nodes_partial() []string {
	mut errs := []string{}
	for i in 0 .. s.nodes.len {
		path := if os.is_abs_path(s.nodes[i].ecu) {
			s.nodes[i].ecu
		} else {
			os.join_path(s.dir, s.nodes[i].ecu)
		}
		doc := toml.parse_file(path) or {
			errs << 'node "${s.nodes[i].name}": parse ${path}: ${err}'
			continue
		}
		s.nodes[i].view = parse_node_view(doc)
	}
	return errs
}

// load_node parses a node's ecu.toml, extracts its NodeView, AND runs the full
// per-node gate. Use this for a COMPLETE node (validation). The dissolution
// generator uses parse_node_view on a PARTIAL node and gates the GENERATED
// output instead.
pub fn load_node(path string) !NodeView {
	doc := toml.parse_file(path) or { return error('parse ${path}: ${err}') }
	mut v := parse_node_view(doc)
	// the node must ALSO pass the FULL per-node gate — not just the structural
	// rules but unknown keys, wrong types, and the nested-comment trap. Run the
	// REAL ecucheck (@VEXE run, so it's the exact gate loom2v builds behind, no
	// drift) and surface its errors: a clean system must imply buildable nodes
	// (REQ-TOPO-005). @VMODROOT = the repo root, so the path holds from any cwd.
	v.config_errors = ecucheck_errors(path)
	return v
}

// parse_node_view extracts the system-relevant slice of a node's ecu.toml with
// NO external gate — the pure parse the generator runs on a partial node.
pub fn parse_node_view(doc toml.Doc) NodeView {
	mut v := NodeView{}
	// [bus.<name>] — the node's local bus interfaces
	if bv := doc.value_opt('bus') {
		for name, _ in bv.as_map() {
			v.local_buses << name
		}
	}
	is_bus := fn [v] (name string) bool {
		return name in v.local_buses
	}
	// [[signal]] from/to a bus = consume/produce on that bus
	if sv := doc.value_opt('signal') {
		for s in sv.array() {
			v.authored_signals = true // ANY [[signal]] — a dissolved partial has none
			m := s.as_map()
			name := m_str(m, 'name')
			from := m_str(m, 'from')
			to := m_str(m, 'to')
			if name == '' {
				continue
			}
			if is_bus(to) {
				v.produces[to] << name
			}
			if is_bus(from) {
				v.consumes[from] << name
			}
		}
	}
	// [[frame]] with a tx spec = this node transmits that frame on bus
	if fv := doc.value_opt('frame') {
		for f in fv.array() {
			v.authored_frames = true // ANY [[frame]]
			m := f.as_map()
			name := m_str(m, 'name')
			bus := m_str(m, 'bus')
			if name != '' && is_bus(bus) && ('tx' in m) {
				v.tx_frames[bus] << name
			}
		}
	}
	// thread -> partition (to attribute each FB's reads to its partition)
	mut thread_part := map[string]string{}
	for p in (doc.value_opt('partition') or { toml.Any([]toml.Any{}) }).array() {
		pm := p.as_map()
		pname := m_str(pm, 'name')
		for t in (pm['thread'] or { toml.Any([]toml.Any{}) }).array() {
			thread_part[m_str(t.as_map(), 'name')] = pname
		}
	}
	// [[fb]] -> [[fb.handler]] reads/writes: the node's signal intent by name
	// (the authored half of the dissolution — the generator derives the wiring).
	if fbv := doc.value_opt('fb') {
		for fb in fbv.array() {
			fm := fb.as_map()
			part := thread_part[m_str(fm, 'thread')] or { '' }
			for h in (fm['handler'] or { toml.Any([]toml.Any{}) }).array() {
				hm := h.as_map()
				for r in (hm['reads'] or { toml.Any([]toml.Any{}) }).array() {
					name := r.string()
					v.fb_reads << name
					if part != '' && part !in v.read_partitions[name] {
						v.read_partitions[name] << part
					}
				}
				for w in (hm['writes'] or { toml.Any([]toml.Any{}) }).array() {
					v.fb_writes << w.string()
				}
			}
		}
	}
	// [nm] cluster range
	if nmv := doc.value_opt('nm') {
		m := nmv.as_map()
		v.has_nm = true
		v.has_nm_node = 'node' in m // node id 0 is valid — distinguish from absent
		v.nm_node = m_u32(m, 'node')
		v.alive = m_u32(m, 'alive')
		v.has_alive = 'alive' in m // alive = 0 is a valid CAN id — distinguish from absent
		v.nm_msg_cycle_ms = m_int(m, 'msg_cycle_ms')
		v.nm_timeout_ms = m_int(m, 'timeout_ms')
		v.nm_repeat_ms = m_int(m, 'repeat_ms')
		v.nm_wait_sleep_ms = m_int(m, 'wait_sleep_ms')
		peers := (m['peers'] or { toml.Any([]toml.Any{}) }).array()
		if peers.len == 2 {
			v.peers_lo = u32(peers[0].int())
			v.peers_hi = u32(peers[1].int())
		}
	}
	// [target] / [telemetry] — the generated NM only runs on the threadx target
	// with a telemetry bus. A [[route]] in a partial is authored wiring.
	if tv := doc.value_opt('target') {
		v.is_threadx = (tv.as_map()['kind'] or { toml.Any('') }).string() == 'threadx'
	}
	if tlv := doc.value_opt('telemetry') {
		tm := tlv.as_map()
		// loom2v's threadx gate needs BOTH a bus AND telemetry on (m.telem.on).
		// parse_telemetry defaults an OMITTED `enabled` to FALSE, so [telemetry]
		// with a bus but no enabled key does NOT give a threadx node its channel —
		// mirror that default (true would wrongly pass a node loom2v then panics on).
		telem_on := (tm['enabled'] or { toml.Any(false) }).bool()
		v.has_telemetry = telem_on && m_str(tm, 'bus') != ''
		// the on-wire telemetry frame ids (0 = defaulted by loom2v, but an explicit
		// id is what collides — record presence so the ownership check sees only
		// authored ids).
		v.has_telem_id = 'id' in tm
		v.telem_id = m_u32(tm, 'id')
		v.has_telem_det = 'detail_id' in tm
		v.telem_detail_id = m_u32(tm, 'detail_id')
	}
	if _ := doc.value_opt('route') {
		v.authored_routes = true
	}
	return v
}

// ecucheck_errors runs the real per-node gate (tools/ecucheck) on a node's
// ecu.toml and returns its error lines (empty = clean). Shelling to @VEXE keeps
// this the EXACT validation loom2v builds behind — no re-implementation to
// drift. ecucheck prints "<file>: <msg>" per error and a "ecucheck: N …"
// summary, then exits non-zero; we keep the messages, drop the summary/prefix.
pub fn ecucheck_errors(node_path string) []string {
	res := os.execute('${@VEXE} run ${@VMODROOT}/tools/ecucheck/gen.v "${node_path}"')
	if res.exit_code == 0 {
		return []string{}
	}
	fname := os.file_name(node_path)
	mut out := []string{}
	for line in res.output.split_into_lines() {
		t := line.trim_space()
		if t == '' || t.starts_with('ecucheck:') {
			continue // the count summary, not an error
		}
		// strip the leading "<fname>: " ecucheck prepends
		out << t.trim_string_left('${fname}: ')
	}
	if out.len == 0 {
		// ecucheck failed for a reason it didn't print as a schema error (a
		// build/parse failure) — surface something rather than swallow it.
		out << 'ecucheck failed (exit ${res.exit_code})'
	}
	return out
}

// loom2v_errors runs the REAL generator (tools/loom2v) on a node's ecu.toml with
// its bus DBC, returning any panic lines (empty = clean). ecucheck validates the
// SCHEMA; loom2v enforces TARGET-BRIDGE constraints ecucheck cannot see — a
// threadx comm thread packs an external signal as a plain unsigned LE 32-bit
// value at bit 0, so a 16-bit/signed/offset DBC signal, an extended id, an
// E2E/SecOC frame, or a non-cyclic tx mode panics. Shelling the generator keeps
// the gate EXACT (no reimplementation to drift), so "clean syscheck" implies a
// node that actually generates (REQ-TOPO-005). Outputs go to a temp dir and are
// discarded — only the exit code / diagnostics matter.
pub fn loom2v_errors(node_path string, dbc_path string) []string {
	tmp := os.join_path(os.temp_dir(), 'sysgen_loom_${os.getpid()}_${os.file_name(node_path)}')
	os.mkdir_all(tmp) or { return ['loom2v: cannot create temp dir: ${err}'] }
	defer {
		os.rmdir_all(tmp) or {}
	}
	sig := os.join_path(tmp, 'signals.v')
	ports := os.join_path(tmp, 'ports.v')
	glue := os.join_path(tmp, 'glue.v')
	man := os.join_path(tmp, 'manifest.toml')
	res := os.execute('${@VEXE} run ${@VMODROOT}/tools/loom2v "${node_path}" "${dbc_path}" "${sig}" "${ports}" "${glue}" "${man}"')
	if res.exit_code == 0 {
		return []string{}
	}
	mut out := []string{}
	for line in res.output.split_into_lines() {
		t := line.trim_space()
		// keep the generator's own diagnostics (its panics/errors carry "loom2v:");
		// V prefixes a runtime panic with "V panic:" — keep that line's message too.
		if t.contains('loom2v:') {
			out << t.all_after('loom2v:').trim_space()
		}
	}
	if out.len == 0 {
		out << 'loom2v generation failed (exit ${res.exit_code})'
	}
	return out
}
