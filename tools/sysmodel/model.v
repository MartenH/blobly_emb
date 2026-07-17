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
import tools.candb

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
	nm_alloc_ok  bool // whether the allocated `nm` is in loom2v's 0..255 range
	diag         Diag
	trace        int
	// --- extracted from the node's ecu.toml (filled by load_node) ---
	view NodeView
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
	nm_node_ok  bool // whether [nm].node is in loom2v's 0..255 range
	alive      u32 // the node's [nm] alive id (the on-wire id, within peers)
	has_alive  bool // whether [nm].alive was declared (alive = 0 is a valid CAN id)
	peers_lo   u32
	peers_hi   u32
	has_nm        bool   // an [nm] table is present
	nm_enabled    bool   // [nm].enabled (default true) — false = a non-participant node
	nm_bus        string // the bus this node runs NM on (nm.bus, else the telemetry bus)
	alive_binding string // [nm].alive when it is a DBC message NAME (not a numeric id)
	is_threadx    bool   // [target].kind == "threadx" (loom2v generates NM only then)
	is_baremetal  bool   // [target].kind == "baremetal" (loom2v rejects bus signals there)
	has_telemetry bool   // a [telemetry] block with a bus (loom2v requires it for threadx)
	telem_bus     string // [telemetry].bus resolved to its interface
	// the telemetry frames the threadx comm thread transmits on the telemetry bus
	// (CpuLoad + its detail). REAL tx ids: unique across nodes, not colliding with
	// an application frame or the NM range (REQ-TOPO-002). CpuLoad is always sent
	// (effective id, 0 if omitted); the detail only when detail_id != 0.
	telem_id        u32
	telem_detail_id u32
	// per local-bus-interface FD flag: loom2v's threadx FDCAN backend is
	// classic-only, so a threadx node on an fd = true telemetry bus can't build.
	local_bus_fd map[string]bool
	// [trace]: a threadx node streams the raw exec-hook trace as ONE frame per
	// record (record_id, default 0x7e5) on the telemetry channel — a REAL tx frame
	// that must not collide with telemetry/application/NM ids (REQ-TOPO-002). (The
	// cmd/rsp/dump_fc protocol is host-only, not emitted on the threadx target.)
	trace_on          bool
	trace_record_id   u32
	trace_record_name string // a DBC message NAME binding (resolved against the bus DBC)
	// NM timing presence: loom2v applies its default only when the KEY is ABSENT,
	// so an explicit 0 must be preserved (not normalized to the default).
	nm_has_msg_cycle  bool
	nm_has_timeout    bool
	nm_has_repeat     bool
	nm_has_wait_sleep bool
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
}

// System — the whole parsed system.toml plus each node's loaded view.
pub struct System {
pub mut:
	buses        []Bus
	nodes        []Node
	routes       []Route
	unknown_keys []string // top-level sections that aren't part of the schema (typos)
	dir          string   // directory of system.toml (node/dbc paths resolve against it)
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
	// flag unknown top-level sections (a misspelled [[nodes]] would otherwise
	// parse to zero nodes and pass silently). `signal` is the dissolution's
	// system-scope signal section (forward-compatible with the composed model).
	allowed := ['bus', 'node', 'route', 'signal']
	for key, _ in doc.to_any().as_map() {
		if key !in allowed {
			sys.unknown_keys << key
		}
	}
	// [bus.<name>] — a table of tables keyed by name
	if bv := doc.value_opt('bus') {
		for name, cfg in bv.as_map() {
			m := cfg.as_map()
			sys.buses << Bus{
				name:      name
				interface: m_str(m, 'interface')
				fd:        m_bool(m, 'fd')
				bitrate:   m_int(m, 'bitrate')
				dbc:       m_str(m, 'dbc')
			}
		}
	}
	// [[node]]
	if nv := doc.value_opt('node') {
		for n in nv.array() {
			m := n.as_map()
			nm_raw := (m['nm'] or { toml.Any(0) }).int() // signed, to range-check
			mut node := Node{
				name:         m_str(m, 'name')
				ecu:          m_str(m, 'ecu')
				nm:           u32(nm_raw)
				has_nm_alloc: 'nm' in m
				nm_alloc_ok:  nm_raw >= 0 && nm_raw <= 255
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
	mut dbc_cache := map[string]candb.Database{}
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
		// resolve a NAMED [nm].alive binding to its numeric on-wire id via the
		// node's NM-bus DBC, so it flows through the SAME numeric alive-uniqueness
		// check — a name and a literal that hit the same CAN id are a collision the
		// separate name/number maps would miss (REQ-TOPO-002). On success the
		// binding is cleared; if it can't be resolved it stays for the name-level
		// fallback check (two nodes naming the same message collide even undecoded).
		// Only for an ACTIVE NM node: loom2v's parse_nm returns early for enabled =
		// false (and a non-threadx node emits no NM), so an inactive [nm] has no live
		// alive id to resolve — requiring a DBC there would reject a buildable node.
		if s.nodes[i].view.alive_binding != '' && s.nodes[i].view.nm_enabled {
			name := s.nodes[i].view.alive_binding
			// a named alive binding MUST resolve to a numeric CAN id (loom2v does),
			// or its collision + in-range checks are silently skipped. An NM bus with
			// no DBC (or no matching system bus) cannot resolve it — that is a config
			// error, not a clean fall-through (REQ-TOPO-004).
			b := s.bus_by_interface(s.nodes[i].view.nm_bus) or {
				errs << 'node "${s.nodes[i].name}": [nm].alive names "${name}" but its NM bus "${s.nodes[i].view.nm_bus}" maps to no system bus with a DBC to resolve it'
				continue
			}
			if b.dbc == '' {
				errs << 'node "${s.nodes[i].name}": [nm].alive names "${name}" but its NM bus "${b.name}" has no `dbc` to resolve the name to a CAN id'
				continue
			}
			dpath := if os.is_abs_path(b.dbc) { b.dbc } else { os.join_path(s.dir, b.dbc) }
			db := dbc_cache[dpath] or {
				loaded := candb.load_dbc_file(dpath) or {
					errs << 'node "${s.nodes[i].name}": cannot load DBC "${b.dbc}" to resolve [nm].alive "${name}": ${err}'
					continue
				}
				dbc_cache[dpath] = loaded
				loaded
			}
			mut hit := false
			for msg in db.messages {
				if msg.name == name {
					s.nodes[i].view.alive = msg.id
					s.nodes[i].view.has_alive = true
					s.nodes[i].view.alive_binding = ''
					hit = true
					break
				}
			}
			if !hit {
				errs << 'node "${s.nodes[i].name}": [nm].alive names "${name}" but DBC "${b.dbc}" has no such message'
			}
		}
	}
	return errs
}

// load_node parses a node's ecu.toml and extracts its NodeView.
pub fn load_node(path string) !NodeView {
	doc := toml.parse_file(path) or { return error('parse ${path}: ${err}') }
	mut v := NodeView{}
	// the node must ALSO pass the FULL per-node gate — not just the structural
	// rules but unknown keys, wrong types, and the nested-comment trap. Run the
	// REAL ecucheck (@VEXE run, so it's the exact gate loom2v builds behind, no
	// drift) and surface its errors: a clean system must imply buildable nodes
	// (REQ-TOPO-005). @VMODROOT = the repo root, so the path holds from any cwd.
	v.config_errors = ecucheck_errors(path)
	// [bus.<name>] — the node's local bus tables. The table KEY is the node's
	// LOGICAL name (used by signal from/to); its `interface` field is the PLATFORM
	// binding (the physical channel). A node is matched to a system bus by
	// INTERFACE, not by the logical key — so produces/consumes/tx_frames + the
	// local-bus set are keyed by the resolved interface (else `[bus.can0]
	// interface = "can1"` would be credited to the wrong system bus).
	mut key_iface := map[string]string{} // logical name -> interface
	if bv := doc.value_opt('bus') {
		for name, cfg in bv.as_map() {
			cm := cfg.as_map()
			iface := m_str(cm, 'interface')
			resolved := if iface != '' { iface } else { name }
			key_iface[name] = resolved
			v.local_buses << resolved
			v.local_bus_fd[resolved] = m_bool(cm, 'fd')
		}
	}
	iface_of := fn [key_iface] (logical string) ?string {
		return key_iface[logical] or { none }
	}
	// [[signal]] from/to a bus = consume/produce on that bus (keyed by interface)
	if sv := doc.value_opt('signal') {
		for s in sv.array() {
			m := s.as_map()
			name := m_str(m, 'name')
			from := m_str(m, 'from')
			to := m_str(m, 'to')
			if name == '' {
				continue
			}
			if iface := iface_of(to) {
				v.produces[iface] << name
			}
			if iface := iface_of(from) {
				v.consumes[iface] << name
			}
		}
	}
	// [[frame]] with a tx spec = this node transmits that frame on bus
	if fv := doc.value_opt('frame') {
		for f in fv.array() {
			m := f.as_map()
			name := m_str(m, 'name')
			bus := m_str(m, 'bus')
			if name != '' && ('tx' in m) {
				if iface := iface_of(bus) {
					v.tx_frames[iface] << name
				}
			}
		}
	}
	// [target].kind — loom2v generates NM only for the threadx target (it forces
	// nm.on = false otherwise), so a non-threadx node is a NM non-participant.
	mut target_threadx := false
	mut target_baremetal := false
	if tv := doc.value_opt('target') {
		kind := (tv.as_map()['kind'] or { toml.Any('') }).string()
		target_threadx = kind == 'threadx'
		target_baremetal = kind == 'baremetal'
	}
	v.is_threadx = target_threadx
	v.is_baremetal = target_baremetal
	// [telemetry] — loom2v requires it (with a bus) for the threadx target, and
	// uses its bus as the implicit NM bus when [nm].bus is absent.
	if tlv := doc.value_opt('telemetry') {
		tm := tlv.as_map()
		tbus := m_str(tm, 'bus')
		// loom2v's threadx gate requires BOTH a telemetry bus AND telemetry on
		// (m.telem.on). parse_telemetry defaults an OMITTED `enabled` to FALSE, so
		// [telemetry] with a bus but no enabled key does NOT satisfy the gate —
		// mirror that default (true would wrongly pass a node loom2v then panics on).
		telem_on := (tm['enabled'] or { toml.Any(false) }).bool()
		v.telem_bus = key_iface[tbus] or { tbus }
		v.has_telemetry = telem_on && tbus != ''
		// the on-wire telemetry frame ids (omitted -> 0; CpuLoad is always sent,
		// so an omitted id still transmits at 0 — see check_telemetry_frames).
		v.telem_id = m_u32(tm, 'id')
		v.telem_detail_id = m_u32(tm, 'detail_id')
	}
	// [trace] — for the threadx target this streams the exec-hook record frame on
	// the telemetry channel (record_id, default 0x7e5). parse_trace defaults an
	// omitted `enabled` to TRUE when the block is present.
	if trv := doc.value_opt('trace') {
		trm := trv.as_map()
		v.trace_on = (trm['enabled'] or { toml.Any(true) }).bool()
		if v.trace_on {
			if rv := trm['record'] {
				if rv is string {
					v.trace_record_name = rv // a DBC name; resolved in the check
					v.trace_record_id = 0x7e5
				} else {
					v.trace_record_id = u32(rv.int())
				}
			} else {
				v.trace_record_id = 0x7e5
			}
		}
	}
	// [nm] cluster + identity
	if nmv := doc.value_opt('nm') {
		m := nmv.as_map()
		v.has_nm = true
		// enabled = false OR a non-threadx target = a declared-but-inactive NM
		// (loom2v emits no NM): a non-participant, so the cluster/alive/allocation/
		// uniqueness checks skip it.
		v.nm_enabled = (m['enabled'] or { toml.Any(true) }).bool() && target_threadx
		// the bus this node runs NM on: [nm].bus if set, else the telemetry bus
		// (loom2v uses m.telem.bus when nm.bus is absent), resolved to its interface.
		nmbus := m_str(m, 'bus')
		if nmbus != '' {
			v.nm_bus = key_iface[nmbus] or { nmbus }
		} else {
			v.nm_bus = v.telem_bus
		}
		v.has_nm_node = 'node' in m // node id 0 is valid — distinguish from absent
		// keep the SIGNED value long enough to range-check: loom2v rejects a node
		// id outside 0..255, but m_u32 would turn -1 into a huge value that could
		// collide (REQ-TOPO-005 "clean system => buildable nodes").
		node_raw := (m['node'] or { toml.Any(0) }).int()
		v.nm_node = u32(node_raw)
		v.nm_node_ok = node_raw >= 0 && node_raw <= 255
		// peers range: loom2v defaults an omitted range to 0x500..0x53f (its NmCfg
		// defaults), and derives alive from that base — so default it here too.
		peers := (m['peers'] or { toml.Any([]toml.Any{}) }).array()
		if peers.len == 2 {
			v.peers_lo = u32(peers[0].int())
			v.peers_hi = u32(peers[1].int())
		} else {
			v.peers_lo = 0x500
			v.peers_hi = 0x53f
		}
		// alive: NUMERIC literal -> that id; DBC message NAME -> loom2v resolves it
		// to a CAN id (record the NAME for a name-level collision check); ABSENT ->
		// loom2v derives peers_lo + node, so derive + range-check the SAME value.
		if av := m['alive'] {
			if av is string {
				v.alive_binding = av
			} else {
				v.alive = u32(av.int())
				v.has_alive = true
			}
		} else if v.has_nm_node {
			v.alive = v.peers_lo + v.nm_node
			v.has_alive = true
		}
		// timing: presence tracked so an EXPLICIT 0 is preserved (loom2v applies
		// its default only when the key is ABSENT — an explicit 0 stays 0).
		v.nm_has_msg_cycle = 'msg_cycle_ms' in m
		v.nm_has_timeout = 'timeout_ms' in m
		v.nm_has_repeat = 'repeat_ms' in m
		v.nm_has_wait_sleep = 'wait_sleep_ms' in m
		v.nm_msg_cycle_ms = m_int(m, 'msg_cycle_ms')
		v.nm_timeout_ms = m_int(m, 'timeout_ms')
		v.nm_repeat_ms = m_int(m, 'repeat_ms')
		v.nm_wait_sleep_ms = m_int(m, 'wait_sleep_ms')
	}
	return v
}

// run_capture runs `exe` with an ARGUMENT VECTOR (never a shell command string),
// so a node/DBC path containing shell metacharacters (`$(...)`, backticks, `;`)
// is passed to the child literally and can never trigger command substitution —
// syscheck loads whatever paths a system.toml names, so those are untrusted
// input. Returns combined stdout+stderr and the exit code.
fn run_capture(exe string, args []string) (string, int) {
	mut p := os.new_process(exe)
	p.set_args(args)
	p.set_redirect_stdio()
	p.run()
	out := p.stdout_slurp() + p.stderr_slurp()
	p.wait()
	code := p.code
	p.close()
	return out, code
}

// ecucheck_errors runs the real per-node gate (tools/ecucheck) on a node's
// ecu.toml and returns its error lines (empty = clean). Running the REAL @VEXE
// keeps this the EXACT validation loom2v builds behind — no re-implementation to
// drift. ecucheck prints "<file>: <msg>" per error and a "ecucheck: N …"
// summary, then exits non-zero; we keep the messages, drop the summary/prefix.
fn ecucheck_errors(node_path string) []string {
	output, code := run_capture(@VEXE, ['run', '${@VMODROOT}/tools/ecucheck/gen.v', node_path])
	if code == 0 {
		return []string{}
	}
	fname := os.file_name(node_path)
	mut out := []string{}
	for line in output.split_into_lines() {
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
		out << 'ecucheck failed (exit ${code})'
	}
	return out
}
