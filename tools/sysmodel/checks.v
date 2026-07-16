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
	issues << check_identity_uniqueness(s)
	issues << check_bus_single_writer(s)
	issues << check_nm_cluster_coherence(s)
	issues << check_routes(s)
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
		if n.nm != 0 {
			if prev := nm_seen[n.nm] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'NM id 0x${n.nm.hex()} shared by "${prev}" and "${n.name}"'
				}
			} else {
				nm_seen[n.nm] = n.name
			}
			// the node's authored ecu.toml must agree with system.toml (REQ-TOPO-005)
			if n.view.has_nm && n.view.nm_node != 0 && n.view.nm_node != n.nm {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-005'
					msg:      'node "${n.name}": ecu.toml [nm] node 0x${n.view.nm_node.hex()} disagrees with system.toml nm 0x${n.nm.hex()}'
				}
			}
		}
		if n.view.alive != 0 {
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
		if n.diag.req != 0 {
			if prev := diag_seen[n.diag.req] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'diagnostic request id 0x${n.diag.req.hex()} shared by "${prev}" and "${n.name}"'
				}
			} else {
				diag_seen[n.diag.req] = n.name
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
		// a node's ALIVE id (the on-wire NM id, = peers base + node) must fall
		// inside the cluster range it participates in — the node id itself is a
		// small ordinal, not a wire id.
		for n in s.nodes {
			if bus.name !in n.buses || !n.view.has_nm || n.view.alive == 0 || anchor == '' {
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

// signal_routed_to reports whether a route carries `sig` INTO `bus` (so a
// consumer there is satisfied by the gateway, not a local producer).
fn signal_routed_to(s System, sig string, bus string) bool {
	dst := bus
	for r in s.routes {
		if r.to == dst && (r.signal == sig || r.frame == sig) {
			return true
		}
	}
	return false
}

// signal_routed_from reports whether a route carries `sig` OUT of `bus` (so a
// producer there is "used" by the gateway even if no local node consumes it).
fn signal_routed_from(s System, sig string, bus string) bool {
	for r in s.routes {
		if r.from == bus && (r.signal == sig || r.frame == sig) {
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
