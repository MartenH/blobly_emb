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
	issues << check_telemetry_frames(s)
	issues << check_routes(s)
	return issues
}

// The system contract must be well-formed before the semantic checks trust it:
// bus interfaces and node names are LOOKUP KEYS. A duplicate interface lets two
// system buses alias one physical channel (a route between them crosses no wire);
// a duplicate node name makes route resolution pick the wrong gateway
// (REQ-TOPO-002/006).
fn check_topology_wellformed(s System) []Issue {
	mut issues := []Issue{}
	// a parseable-but-empty/typo'd system must not pass as a clean build gate:
	// no buses or no nodes (e.g. a misspelled [[nodes]]) is not a system.
	if s.buses.len == 0 {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-001'
			msg:      'no [bus.*] declared — a system needs at least one bus'
		}
	}
	if s.nodes.len == 0 {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-001'
			msg:      'no [[node]] declared — a system needs at least one node (check for a typo like [[nodes]])'
		}
	}
	for k in s.unknown_keys {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-001'
			msg:      'unknown top-level section "${k}" in system.toml (expected bus / node / signal / route)'
		}
	}
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
		// ecucheck validates SCHEMA, not target-dependent generator constraints:
		// loom2v panics for a threadx target without a [telemetry] bus, so a clean
		// syscheck would otherwise not imply a buildable node (REQ-TOPO-005).
		if n.view.is_threadx && !n.view.has_telemetry {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'node "${n.name}": target is threadx but has no [telemetry] bus (loom2v requires it for the threadx target)'
			}
		}
		// loom2v's threadx FDCAN backend is classic-only and panics when the
		// telemetry bus has fd = true (blob_can_open rejects fd_mode), so a threadx
		// node on an fd bus is not buildable (REQ-TOPO-005).
		if n.view.is_threadx && n.view.has_telemetry && (n.view.local_bus_fd[n.view.telem_bus] or {
			false
		}) {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'node "${n.name}": target is threadx but its telemetry bus "${n.view.telem_bus}" has fd = true — loom2v\'s FDCAN backend here is classic-only'
			}
		}
		// loom2v's baremetal superloop has NO comm bridge and panics for any
		// external/bus signal ("baremetal does not support external/bus signals
		// yet"); only the threadx comm thread services bus traffic. So a baremetal
		// node with a bus-facing producer/consumer is not buildable (REQ-TOPO-005).
		if n.view.is_baremetal && node_has_bus_signal(n) {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'node "${n.name}": target is baremetal but has bus-facing signals (produces/consumes on a bus) — loom2v\'s baremetal superloop has no comm bridge; only the threadx target services bus signals'
			}
		}
			// loom2v's threadx comm thread owns ONLY the telemetry bus and panics for a
			// TX or RX signal on any other bus (gen.v). Every bus-facing signal of a
			// threadx node must ride its telemetry bus; a signal on another claimed system
			// bus is not generatable until a per-bus comm owner exists (P2, REQ-TOPO-005).
			if n.view.is_threadx && n.view.has_telemetry {
				for iface, sigs in n.view.produces {
					if sigs.len > 0 && iface != n.view.telem_bus {
						issues << Issue{
							severity: .error
							req:      'REQ-TOPO-005'
							msg:      'node "${n.name}": transmits ${sigs} on bus "${iface}" but its threadx comm thread owns only the telemetry bus "${n.view.telem_bus}" (one comm bus per node in P1)'
						}
					}
				}
				for iface, sigs in n.view.consumes {
					if sigs.len > 0 && iface != n.view.telem_bus {
						issues << Issue{
							severity: .error
							req:      'REQ-TOPO-005'
							msg:      'node "${n.name}": receives ${sigs} on bus "${iface}" but its threadx comm thread owns only the telemetry bus "${n.view.telem_bus}" (one comm bus per node in P1)'
						}
					}
				}
			}
		// loom2v runs NM inside the comm thread, which owns the TELEMETRY bus —
		// [nm].bus only labels the manifest (gen_nm.v), it does NOT move NM's tx.
		// So an explicit nm.bus other than the telemetry bus is a lie: syscheck
		// would scope cluster coherence to nm.bus while the node physically runs
		// NM on telem.bus (REQ-TOPO-004). (nm.bus absent -> nm_bus == telem_bus,
		// so this only fires on an explicit, divergent nm.bus.)
		if n.view.is_threadx && n.view.has_telemetry && n.view.nm_enabled
			&& n.view.nm_bus != n.view.telem_bus {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-004'
				msg:      'node "${n.name}": [nm].bus "${n.view.nm_bus}" differs from [telemetry].bus "${n.view.telem_bus}" — loom2v runs NM on the telemetry bus, so nm.bus must match it (multi-bus NM ownership is not generated yet)'
			}
		}
	}
	return issues
}

// node_has_bus_signal reports whether a node transmits or receives any signal on
// a bus (an external/bus-facing [[signal]] endpoint). produces/consumes are keyed
// by the node's local interface; any non-empty entry means bus traffic.
fn node_has_bus_signal(n Node) bool {
	for _, sigs in n.view.produces {
		if sigs.len > 0 {
			return true
		}
	}
	for _, sigs in n.view.consumes {
		if sigs.len > 0 {
			return true
		}
	}
	return false
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
			b := s.bus_by_interface(iface) or {
				// an interface no system bus declares has NO system contract. If it
				// carries real traffic it is invisible to the writer/reachability, the
				// telemetry-frame, and the NM-coherence checks (all keyed by a system
				// bus) — flag it rather than silently drop it. A threadx node also puts
				// telemetry (and NM) on its telem/nm interface, which counts as traffic
				// even with no application signal.
				carries_app := n.view.produces[iface].len > 0 || n.view.consumes[iface].len > 0
				carries_telem := n.view.has_telemetry && iface == n.view.telem_bus
				carries_nm := n.view.has_nm && n.view.nm_enabled && iface == n.view.nm_bus
				if carries_app || carries_telem || carries_nm {
					mut kinds := []string{}
					if carries_app {
						kinds << 'signals'
					}
					if carries_telem {
						kinds << 'telemetry'
					}
					if carries_nm {
						kinds << 'NM'
					}
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-001'
						msg:      'node "${n.name}": opens interface [bus.${iface}] not declared by any system bus, yet carries ${kinds.join("/")} on it — that traffic has no system contract and is never checked for writers, reachability, or frame ownership'
					}
				}
				continue
			}
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
	mut alive_binding_seen := map[string]string{}
	mut diag_seen := map[u32]string{}
	mut trace_seen := map[int]string{}
	for n in s.nodes {
		// key uniqueness/consistency on ALLOCATION PRESENCE, not on a nonzero
		// value — nm id 0 is a valid allocation, so `nm = 0` must not read as
		// "unset" and skip the checks. A disabled [nm] node (has table, enabled=
		// false) is a non-participant: loom2v emits no NM, so its id can't collide
		// and its [nm] fields need not match — skip its NM checks (a missing table
		// with an allocation is still flagged, below).
		// the system allocation itself must be a valid node id (a negative nm would
		// cast to a huge u32 and could false-match another negative one).
		if n.has_nm_alloc && !n.nm_alloc_ok {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-002'
				msg:      'node "${n.name}": system.toml nm is outside the 0..255 node-id range'
			}
		}
		disabled := n.view.has_nm && !n.view.nm_enabled
		if n.has_nm_alloc && !disabled {
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
			} else if !n.view.nm_node_ok {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-005'
					msg:      'node "${n.name}": ecu.toml [nm] node is outside the 0..255 range loom2v requires'
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
		if n.view.has_nm && n.view.nm_enabled && !n.has_nm_alloc {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'node "${n.name}": has an active [nm] block but system.toml allocates it no `nm` — every NM identity must be system-allocated'
			}
		}
		if n.view.has_alive && n.view.nm_enabled {
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
		// FALLBACK for a named alive binding load_nodes could NOT resolve to a
		// numeric id (no DBC on the bus): two nodes naming the same DBC message
		// still share one on-wire alive id, even undecoded (REQ-TOPO-002). A
		// RESOLVED binding is cleared to '' and already caught numerically above.
		if n.view.alive_binding != '' && n.view.nm_enabled {
			if prev := alive_binding_seen[n.view.alive_binding] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'alive binding "${n.view.alive_binding}" named by both "${prev}" and "${n.name}" — it resolves to one CAN id'
				}
			} else {
				alive_binding_seen[n.view.alive_binding] = n.name
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
			if !nm_participates(n, bus) {
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
				if !nm_participates(n, bus) {
					continue
				}
				// compare the EFFECTIVE value (declared, or loom2v's default) — a node
				// that OMITS a timing still runs at the default, so an omission vs an
				// explicit change IS a mismatch.
				val := nm_timing_effective(n.view, param)
				if ref_node == '' {
					ref = val
					ref_node = n.name
				} else if val != ref {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-004'
						msg:      'bus "${bus.name}": NM ${param} mismatch — "${ref_node}"=${ref} vs "${n.name}"=${val} (effective, incl. defaults)'
					}
				}
			}
		}
		// a node's ALIVE id (the on-wire NM id, = peers base + node) must fall
		// inside the cluster range it participates in — the node id itself is a
		// small ordinal, not a wire id.
		for n in s.nodes {
			if !nm_participates(n, bus) || !n.view.has_alive || anchor == '' {
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

// nm_participates reports whether a node is an active member of a system bus's
// NM cluster. [nm] has ONE `bus` binding (loom2v runs the module on that bus
// only), so a node with an explicit nm.bus participates ONLY on that bus — a
// gateway on compute+edge with nm.bus="compute" is not compared to edge's
// cluster. With no explicit nm.bus it participates on the bus(es) it claims.
fn nm_participates(n Node, bus Bus) bool {
	if bus.name !in n.buses || !n.view.has_nm || !n.view.nm_enabled {
		return false
	}
	if n.view.nm_bus != '' {
		return n.view.nm_bus == bus.interface
	}
	return true
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

// nm_default is loom2v's default for an omitted NM timing (tools/loom2v/gen_nm.v)
// — kept in lockstep so coherence compares what loom2v actually emits.
fn nm_default(param string) int {
	return match param {
		'msg_cycle_ms' { 100 }
		'timeout_ms' { 300 }
		'repeat_ms' { 200 }
		'wait_sleep_ms' { 150 }
		else { 0 }
	}
}

// nm_has reports whether a timing KEY was declared (an explicit 0 counts).
fn nm_has(v NodeView, param string) bool {
	return match param {
		'msg_cycle_ms' { v.nm_has_msg_cycle }
		'timeout_ms' { v.nm_has_timeout }
		'repeat_ms' { v.nm_has_repeat }
		'wait_sleep_ms' { v.nm_has_wait_sleep }
		else { false }
	}
}

// nm_timing_effective returns the node's declared value (even an explicit 0), or
// loom2v's default ONLY when the key is ABSENT — matching loom2v, which defaults
// on absence, not on a zero value.
fn nm_timing_effective(v NodeView, param string) int {
	return if nm_has(v, param) { nm_timing(v, param) } else { nm_default(param) }
}

// REQ-TOPO-006: every route references a real gateway that sits on BOTH buses,
// names distinct from/to buses, and carries exactly one of frame/signal.
fn check_routes(s System) []Issue {
	mut issues := []Issue{}
	for r in s.routes {
		// P1 does NOT generate cross-bus routing: sysgen never passes a system route
		// into a node's ecu.toml, and loom2v only parses node-local [[route]] entries
		// (raw-frame-only). So a system route — a SIGNAL route especially — would let
		// syscheck pass while no gateway forwards it at runtime. Reject it until the
		// gateway wiring is generated (P2). The well-formedness checks below still run
		// so a malformed route is caught too, ready for when generation lands.
		kind := if r.signal != '' { 'signal' } else { 'frame' }
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-006'
			msg:      'route on "${r.gateway}" (${kind} "${r.signal}${r.frame}", ${r.from} -> ${r.to}): cross-bus routing is not generated in P1 — sysgen/loom2v do not emit system routes yet (P2), so a clean verdict would not imply a forwarder exists'
		}
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
		if r.from == '' || r.to == '' {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-006'
				msg:      'route on "${r.gateway}": needs both `from` and `to` buses (a route with one endpoint carries nothing)'
			}
		}
		if r.from == r.to && r.from != '' {
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
