// sysmodel/checks — the SYSTEM-level validation (docs/multi-node.md "the real
// value: system-level validation"). These are the checks a single ecu.toml
// cannot do because it cannot see its peers. Each maps to a REQ-TOPO-* the way
// the per-node rules map to REQ-COM/NM.
//
// validate_system returns every issue (empty = clean) with a severity, so the
// CLI can exit non-zero on an error and still surface warnings.
module sysmodel

pub enum Severity {
	error
	warning
}

pub struct Issue {
pub:
	severity Severity
	req      string // the REQ-TOPO-* this check enforces
	msg      string
}

// validate_system runs all cross-node checks against a System whose nodes have
// been loaded (see load_nodes). Order: identity first (a shared id poisons
// everything), then per-bus single-writer/reachability, then NM coherence,
// then routes.
pub fn validate_system(s System) []Issue {
	mut issues := []Issue{}
	issues << check_topology_wellformed(s)
	issues << check_node_configs(s)
	issues << check_bus_membership(s)
	issues << check_identity_uniqueness(s)
	issues << check_bus_single_writer(s)
	issues << check_frame_single_writer(s)
	issues << check_nm_cluster_coherence(s)
	issues << check_routes(s)
	return issues
}

// validate_system_gen — the checks for the DISSOLUTION model (docs/multi-node.md
// P1b): cross-node signals are declared once in system.toml with a producer, and
// nodes carry only FB read/write intent. Identity/NM/route checks are shared
// with the composed model; single-writer/reachability come from the producer +
// FB intent instead of per-node [[signal]] endpoints. (The per-node ecucheck
// runs on the GENERATED output, in sysgen — a partial node can't pass alone.)
pub fn validate_system_gen(s System) []Issue {
	mut issues := []Issue{}
	issues << check_topology_wellformed(s)
	issues << check_identity_alloc(s)
	issues << check_routes(s)
	issues << check_signals_dissolved(s)
	return issues
}

// check_identity_alloc: uniqueness of the SYSTEM-ALLOCATED ids (dissolution).
// The [nm]/alive/timing are GENERATED into each node from system.toml, so there
// is no authored node identity to cross-check and the cluster is coherent by
// construction — only uniqueness across the allocations matters (REQ-TOPO-002).
// (alive = peers base + nm, so it is unique whenever nm is.)
fn check_identity_alloc(s System) []Issue {
	mut issues := []Issue{}
	mut nm_seen := map[u32]string{}
	mut diag_seen := map[u32]string{}
	mut trace_seen := map[int]string{}
	for n in s.nodes {
		if n.has_nm_alloc {
			if prev := nm_seen[n.nm] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'NM id 0x${n.nm.hex()} shared by "${prev}" and "${n.name}"'
				}
			} else {
				nm_seen[n.nm] = n.name
			}
		}
		for kind, id in {
			'request':  n.diag.req
			'response': n.diag.rsp
		} {
			if id == 0 {
				continue
			}
			if prev := diag_seen[id] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'diagnostic ${kind} id 0x${id.hex()} (node "${n.name}") collides with an id already used by "${prev}"'
				}
			} else {
				diag_seen[id] = n.name
			}
		}
		if n.trace != 0 {
			if prev := trace_seen[n.trace] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'trace node id ${n.trace} shared by "${prev}" and "${n.name}"'
				}
			} else {
				trace_seen[n.trace] = n.name
			}
		}
	}
	return issues
}

// check_signals_dissolved: single-writer + reachability over system-scope
// signals. Each SysSignal has exactly one declared producer (REQ-TOPO-001) that
// sits on the signal's bus and actually WRITES it (REQ-TOPO-005 consistency); a
// signal an FB writes but the system doesn't declare, or two signals sharing a
// DBC frame across producers, is a bug; a signal no FB reads is a warning.
fn check_signals_dissolved(s System) []Issue {
	mut issues := []Issue{}
	mut frame_owner := map[string]string{} // frame -> producer node
	for sig in s.signals {
		// the producer must be a declared node on the signal's bus
		mut prod := ?Node(none)
		for n in s.nodes {
			if n.name == sig.producer {
				prod = n
				break
			}
		}
		p := prod or {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-001'
				msg:      'signal "${sig.name}": producer "${sig.producer}" is not a declared node'
			}
			continue
		}
		if sig.bus !in p.buses {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-001'
				msg:      'signal "${sig.name}": producer "${p.name}" does not sit on its bus "${sig.bus}"'
			}
		}
		// the producer's FBs must actually write it (else nothing drives the tx)
		if sig.name !in p.view.fb_writes {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'signal "${sig.name}": producer "${p.name}" has no FB that writes it'
			}
		}
		// one producer per DBC frame — two signals in one frame from two nodes
		// contend for the PDU on the wire (REQ-TOPO-001)
		if sig.frame != '' {
			if prev := frame_owner[sig.frame] {
				if prev != sig.producer {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-001'
						msg:      'frame "${sig.frame}": carries signals from both "${prev}" and "${sig.producer}" — one frame owner per bus'
					}
				}
			} else {
				frame_owner[sig.frame] = sig.producer
			}
		}
		// reachability: does anyone read it? (a produced-but-unconsumed signal)
		mut consumed := false
		for n in s.nodes {
			if n.name != sig.producer && sig.name in n.view.fb_reads {
				consumed = true
				break
			}
		}
		if !consumed {
			issues << Issue{
				severity: .warning
				req:      'REQ-TOPO-001'
				msg:      'signal "${sig.name}" (producer "${sig.producer}") is read by no other node'
			}
		}
	}
	// an FB that WRITES a name the system never declared can't be wired
	// cross-node (it may be a node-local signal, but P1's dissolution routes all
	// cross-node signals through system.toml — flag the unknown as a warning).
	for n in s.nodes {
		for w in n.view.fb_writes {
			if _ := s.signal_by_name(w) {
				continue
			}
			issues << Issue{
				severity: .warning
				req:      'REQ-TOPO-001'
				msg:      'node "${n.name}": FB writes "${w}" which system.toml does not declare (node-local, or a missing system signal)'
			}
		}
	}
	return issues
}

// The system contract must be well-formed before the semantic checks trust it:
// bus interfaces and node names are LOOKUP KEYS. A duplicate interface lets two
// system buses alias one physical channel (a route between them crosses no wire);
// a duplicate node name makes route resolution pick the wrong gateway
// (REQ-TOPO-002/006).
fn check_topology_wellformed(s System) []Issue {
	mut issues := []Issue{}
	mut iface_seen := map[string]string{}
	for b in s.buses {
		if b.interface == '' {
			continue
		}
		if prev := iface_seen[b.interface] {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-006'
				msg:      'buses "${prev}" and "${b.name}" share interface "${b.interface}" — one system bus per physical channel'
			}
		} else {
			iface_seen[b.interface] = b.name
		}
	}
	mut name_seen := map[string]bool{}
	for n in s.nodes {
		if n.name in name_seen {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-002'
				msg:      'duplicate node name "${n.name}" — node names are the route/identity key and must be unique'
			}
		} else {
			name_seen[n.name] = true
		}
	}
	return issues
}

// A node that can't pass ecucheck can't be generated — surface its structural
// errors (partition core, fb thread, unique names, …) so a clean system verdict
// implies buildable nodes (REQ-TOPO-005).
fn check_node_configs(s System) []Issue {
	mut issues := []Issue{}
	for n in s.nodes {
		for e in n.view.config_errors {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'node "${n.name}" ecu.toml invalid: ${e}'
			}
		}
	}
	return issues
}

// REQ-TOPO-001/005: every bus a node claims must be a declared system bus AND
// map to a local bus in the node's ecu.toml (by that bus's interface). A typo
// in `buses`, or a system bus whose interface the node never opens, would
// otherwise silently drop all of that node's traffic on the bus — its
// collisions and orphaned consumers would go unreported.
fn check_bus_membership(s System) []Issue {
	mut issues := []Issue{}
	for n in s.nodes {
		for bname in n.buses {
			b := s.bus_by_name(bname) or {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-001'
					msg:      'node "${n.name}": bus "${bname}" is not declared in system.toml'
				}
				continue
			}
			if b.interface !in n.view.local_buses {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-005'
					msg:      'node "${n.name}": claims bus "${bname}" but its ecu.toml has no [bus.${b.interface}] interface (declares ${n.view.local_buses})'
				}
			}
		}
		// the reverse: a local interface that matches a system bus must be CLAIMED
		// in `buses`, or producers_on/consumers_on (which filter on `buses`) drop
		// this node's traffic silently — its collisions vanish from the checks.
		for iface in n.view.local_buses {
			b := s.bus_by_interface(iface) or { continue }
			if b.name !in n.buses {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-005'
					msg:      'node "${n.name}": opens interface [bus.${iface}] (system bus "${b.name}") but does not claim "${b.name}" in its buses — its traffic there is unchecked'
				}
			}
		}
	}
	return issues
}

// REQ-TOPO-001: each CAN frame on a bus has exactly one transmitting node. Two
// nodes writing different signals into the same DBC message still contend for
// the same PDU on the wire and overwrite each other's fields — signal-level
// single-writer misses this, so the frame owner is checked directly.
//
// SCOPE: this catches EXPLICIT [[frame]] tx ownership. A signal with `to =
// <bus>` and NO [[frame]] still gets a default transmit frame from loom2v, so
// two nodes writing different signals that map to the SAME DBC message is a
// collision this can't see without resolving signals→messages through the bus
// DBC — that is REQ-TOPO-003 (DBC conformance), deferred pending a DBC parse.
fn check_frame_single_writer(s System) []Issue {
	mut issues := []Issue{}
	for bus in s.buses {
		mut owners := map[string][]string{}
		for n in s.nodes {
			if bus.name !in n.buses {
				continue
			}
			for fr in n.view.tx_frames[bus.interface] {
				owners[fr] << n.name
			}
		}
		for fr, nodes in owners {
			if nodes.len > 1 {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-001'
					msg:      'bus "${bus.name}": frame "${fr}" transmitted by ${nodes.len} nodes (${nodes.join(", ")}) — one frame owner per bus'
				}
			}
		}
	}
	return issues
}

// producers_on returns, for a system bus, a map signal -> [node names that
// transmit it on that bus]. A node produces on bus B the signals its ecu.toml
// sends to B's interface.
fn producers_on(s System, bus Bus) map[string][]string {
	mut prod := map[string][]string{}
	for n in s.nodes {
		if bus.name !in n.buses {
			continue
		}
		for sig in n.view.produces[bus.interface] {
			prod[sig] << n.name
		}
	}
	return prod
}

fn consumers_on(s System, bus Bus) map[string][]string {
	mut cons := map[string][]string{}
	for n in s.nodes {
		if bus.name !in n.buses {
			continue
		}
		for sig in n.view.consumes[bus.interface] {
			cons[sig] << n.name
		}
	}
	return cons
}

// REQ-TOPO-001: on each bus every signal is transmitted by EXACTLY ONE node and
// received by AT LEAST ONE. Two transmitters (a wire collision) is an error; a
// consumer with no producer on its bus (and no route, checked in check_routes)
// is an error; a producer nobody consumes is a warning (unused-signal lint).
fn check_bus_single_writer(s System) []Issue {
	mut issues := []Issue{}
	for bus in s.buses {
		prod := producers_on(s, bus)
		cons := consumers_on(s, bus)
		// two writers of the same signal = a collision on the wire
		for sig, nodes in prod {
			if nodes.len > 1 {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-001'
					msg:      'bus "${bus.name}": signal "${sig}" transmitted by ${nodes.len} nodes (${nodes.join(", ")}) — exactly one writer per bus'
				}
			}
		}
		// a consumer with no producer on THIS bus (a route may still satisfy it —
		// check_routes downgrades those; here we flag the raw gap)
		for sig, nodes in cons {
			if sig !in prod && !signal_routed_to(s, sig, bus.name) {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-001'
					msg:      'bus "${bus.name}": signal "${sig}" consumed by ${nodes.join(", ")} but no node transmits it here (missing producer or route)'
				}
			}
		}
		// a produced signal nobody consumes on this bus = unused (warning)
		for sig, nodes in prod {
			if sig !in cons && !signal_routed_from(s, sig, bus.name) {
				issues << Issue{
					severity: .warning
					req:      'REQ-TOPO-001'
					msg:      'bus "${bus.name}": signal "${sig}" transmitted by ${nodes.join(", ")} but no node consumes it here'
				}
			}
		}
	}
	return issues
}

// REQ-TOPO-002: no two nodes share an NM id, an alive id, a diagnostic address,
// or a trace id. REQ-TOPO-005: each node's own [nm] node id agrees with the id
// system.toml allocates it (the system is the source of identity).
fn check_identity_uniqueness(s System) []Issue {
	mut issues := []Issue{}
	mut nm_seen := map[u32]string{}
	mut alive_seen := map[u32]string{}
	mut diag_seen := map[u32]string{}
	mut trace_seen := map[int]string{}
	for n in s.nodes {
		// key uniqueness/consistency on ALLOCATION PRESENCE, not on a nonzero
		// value — nm id 0 is a valid allocation, so `nm = 0` must not read as
		// "unset" and skip the checks.
		if n.has_nm_alloc {
			if prev := nm_seen[n.nm] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'NM id 0x${n.nm.hex()} shared by "${prev}" and "${n.name}"'
				}
			} else {
				nm_seen[n.nm] = n.name
			}
			// system.toml is the identity SOURCE: a node it allocates an NM id to
			// must declare [nm], with `node`, and with the matching id (REQ-TOPO-005).
			if !n.view.has_nm {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-005'
					msg:      'node "${n.name}": system.toml allocates nm 0x${n.nm.hex()} but its ecu.toml has no [nm] block'
				}
			} else if !n.view.has_nm_node {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-005'
					msg:      'node "${n.name}": system.toml allocates nm 0x${n.nm.hex()} but its [nm] has no `node` id (loom2v requires it)'
				}
			} else if n.view.nm_node != n.nm {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-005'
					msg:      'node "${n.name}": ecu.toml [nm] node 0x${n.view.nm_node.hex()} disagrees with system.toml nm 0x${n.nm.hex()}'
				}
			}
		}
		// a node with a local NM identity the system never allocated: its runtime
		// id is invisible to the uniqueness check above, so two such nodes could
		// collide silently. system.toml must own every NM identity (REQ-TOPO-005).
		if n.view.has_nm && !n.has_nm_alloc {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'node "${n.name}": has a local [nm] block but system.toml allocates it no `nm` — every NM identity must be system-allocated'
			}
		}
		if n.view.has_alive {
			if prev := alive_seen[n.view.alive] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'alive id 0x${n.view.alive.hex()} shared by "${prev}" and "${n.name}"'
				}
			} else {
				alive_seen[n.view.alive] = n.name
			}
		}
		// ALL diagnostic ids (req AND rsp, across every node) must be distinct —
		// two ECUs answering on the same rsp id collide, and one node's rsp equal
		// to another's req cross-wires the two sessions.
		for kind, id in {
			'request':  n.diag.req
			'response': n.diag.rsp
		} {
			if id == 0 {
				continue
			}
			if prev := diag_seen[id] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'diagnostic ${kind} id 0x${id.hex()} (node "${n.name}") collides with an id already used by "${prev}"'
				}
			} else {
				diag_seen[id] = n.name
			}
		}
		if n.trace != 0 {
			if prev := trace_seen[n.trace] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'trace node id ${n.trace} shared by "${prev}" and "${n.name}"'
				}
			} else {
				trace_seen[n.trace] = n.name
			}
		}
	}
	return issues
}

// REQ-TOPO-004: nodes that share a bus form a sleep cluster and must agree on
// the NM cluster range (peers). A node with a mismatched range silently never
// sleeps with the others. Checked per bus (the cluster is bus-scoped until a
// gateway bridges it — P2).
fn check_nm_cluster_coherence(s System) []Issue {
	mut issues := []Issue{}
	for bus in s.buses {
		mut lo := u32(0)
		mut hi := u32(0)
		mut anchor := ''
		for n in s.nodes {
			if bus.name !in n.buses || !n.view.has_nm {
				continue
			}
			if anchor == '' {
				lo = n.view.peers_lo
				hi = n.view.peers_hi
				anchor = n.name
				continue
			}
			if n.view.peers_lo != lo || n.view.peers_hi != hi {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-004'
					msg:      'bus "${bus.name}": NM cluster range mismatch — "${anchor}" has [0x${lo.hex()},0x${hi.hex()}] but "${n.name}" has [0x${n.view.peers_lo.hex()},0x${n.view.peers_hi.hex()}]'
				}
			}
		}
		// the sleep/wake timing must agree too, or the state machines transition
		// at incompatible times. Anchor EACH param on its first non-default
		// declaration (not the cluster anchor) — else a node that omits a param
		// makes every later conflict compare against its 0 and slip through.
		for param in ['msg_cycle_ms', 'timeout_ms', 'repeat_ms', 'wait_sleep_ms'] {
			mut ref := 0
			mut ref_node := ''
			for n in s.nodes {
				if bus.name !in n.buses || !n.view.has_nm {
					continue
				}
				val := nm_timing(n.view, param)
				if val == 0 {
					continue
				}
				if ref_node == '' {
					ref = val
					ref_node = n.name
				} else if val != ref {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-004'
						msg:      'bus "${bus.name}": NM ${param} mismatch — "${ref_node}"=${ref} vs "${n.name}"=${val}'
					}
				}
			}
		}
		// a node's ALIVE id (the on-wire NM id, = peers base + node) must fall
		// inside the cluster range it participates in — the node id itself is a
		// small ordinal, not a wire id.
		for n in s.nodes {
			if bus.name !in n.buses || !n.view.has_nm || !n.view.has_alive || anchor == '' {
				continue
			}
			if n.view.alive < lo || n.view.alive > hi {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-004'
					msg:      'bus "${bus.name}": node "${n.name}" alive id 0x${n.view.alive.hex()} outside its cluster range [0x${lo.hex()},0x${hi.hex()}]'
				}
			}
		}
	}
	return issues
}

// nm_timing pulls one NM sleep/wake parameter by name (0 = unset/defaulted).
fn nm_timing(v NodeView, param string) int {
	return match param {
		'msg_cycle_ms' { v.nm_msg_cycle_ms }
		'timeout_ms' { v.nm_timeout_ms }
		'repeat_ms' { v.nm_repeat_ms }
		'wait_sleep_ms' { v.nm_wait_sleep_ms }
		else { 0 }
	}
}

// REQ-TOPO-006: every route references a real gateway that sits on BOTH buses,
// names distinct from/to buses, and carries exactly one of frame/signal.
fn check_routes(s System) []Issue {
	mut issues := []Issue{}
	for r in s.routes {
		mut gw := ?Node(none)
		for n in s.nodes {
			if n.name == r.gateway {
				gw = n
				break
			}
		}
		g := gw or {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-006'
				msg:      'route: gateway "${r.gateway}" is not a declared node'
			}
			continue
		}
		if r.from == r.to {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-006'
				msg:      'route on "${r.gateway}": from and to are the same bus ("${r.from}")'
			}
		}
		if (r.frame == '') == (r.signal == '') {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-006'
				msg:      'route on "${r.gateway}": set exactly one of frame= / signal= (from "${r.from}" to "${r.to}")'
			}
		}
		for b in [r.from, r.to] {
			if b == '' {
				continue
			}
			if _ := s.bus_by_name(b) {
				if b !in g.buses {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-006'
						msg:      'route on "${r.gateway}": gateway does not sit on bus "${b}"'
					}
				}
			} else {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-006'
					msg:      'route on "${r.gateway}": bus "${b}" is not declared'
				}
			}
		}
	}
	return issues
}

// signal_routed_to reports whether a SIGNAL route carries `sig` INTO `bus` from
// a source bus that ACTUALLY PRODUCES it — only then does the gateway have a
// value to forward, so only then is a consumer on `bus` satisfied (REQ-TOPO-001/
// 006). Frame (raw-PDU) routes are NOT matched here: a frame route names a DBC
// message, not a signal, so resolving which signals it carries needs the DBC
// (REQ-TOPO-003, deferred) — until then a frame route can't satisfy a signal
// consumer.
fn signal_routed_to(s System, sig string, bus string) bool {
	for r in s.routes {
		if r.to != bus || r.signal != sig {
			continue
		}
		src := s.bus_by_name(r.from) or { continue }
		if sig in producers_on(s, src) {
			return true
		}
	}
	return false
}

// signal_routed_from reports whether a SIGNAL route carries `sig` OUT of `bus`
// to a destination that has a consumer (so a producer here is "used" by the
// gateway even if no local node consumes it).
fn signal_routed_from(s System, sig string, bus string) bool {
	for r in s.routes {
		if r.from != bus || r.signal != sig {
			continue
		}
		dst := s.bus_by_name(r.to) or { continue }
		if sig in consumers_on(s, dst) {
			return true
		}
	}
	return false
}

// error_count / has_errors — CLI helpers.
pub fn error_count(issues []Issue) int {
	mut n := 0
	for i in issues {
		if i.severity == .error {
			n++
		}
	}
	return n
}
