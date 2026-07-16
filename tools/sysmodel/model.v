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
import tools.ecumodel

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
	name  string
	ecu   string // path to the node's ecu.toml, relative to system.toml
	buses []string
	nm    u32 // NM node id (0 = unset)
	diag  Diag
	trace int
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
	alive      u32 // the node's [nm] alive id (the on-wire id, within peers)
	peers_lo   u32
	peers_hi   u32
	has_nm     bool
	// node-level structural errors from ecumodel.validate (partition core, fb
	// thread, …) — a system can't be clean if a node can't pass ecucheck.
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
	buses  []Bus
	nodes  []Node
	routes []Route
	dir    string // directory of system.toml (node/dbc paths resolve against it)
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
			mut node := Node{
				name:  m_str(m, 'name')
				ecu:   m_str(m, 'ecu')
				nm:    m_u32(m, 'nm')
				trace: m_int(m, 'trace')
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

// load_node parses a node's ecu.toml and extracts its NodeView.
pub fn load_node(path string) !NodeView {
	doc := toml.parse_file(path) or { return error('parse ${path}: ${err}') }
	mut v := NodeView{}
	// the node must ALSO be a valid single-node config (partition core, fb
	// thread, unique names, …) — else syscheck could call a system clean while
	// its nodes can't pass ecucheck or be generated by loom2v.
	v.config_errors = ecumodel.validate(doc)
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
			m := f.as_map()
			name := m_str(m, 'name')
			bus := m_str(m, 'bus')
			if name != '' && is_bus(bus) && ('tx' in m) {
				v.tx_frames[bus] << name
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
	return v
}
