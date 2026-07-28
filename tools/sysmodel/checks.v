// sysmodel/checks — the SYSTEM-level validation (docs/multi-node.md "the real
// value: system-level validation"). These are the checks a single ecu.toml
// cannot do because it cannot see its peers. Each maps to a REQ-TOPO-* the way
// the per-node rules map to REQ-COM/NM.
//
// validate_system returns every issue (empty = clean) with a severity, so the
// CLI can exit non-zero on an error and still surface warnings.
module sysmodel

import os
import tools.candb

pub enum Severity {
	error
	warning
}

// default_cycle_ms — the tx cadence the generator emits when a signal omits
// cycle_ms. Shared so the cadence-agreement check compares the SAME effective
// value the generator will emit (a signal at 0 and one at 100 are NOT a conflict).
pub const default_cycle_ms = 100

pub fn effective_cycle_ms(cycle_ms int) int {
	return if cycle_ms > 0 { cycle_ms } else { default_cycle_ms }
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
	issues << check_node_generatable(s)
	issues << check_bus_membership(s)
	issues << check_identity_uniqueness(s)
	issues << check_bus_single_writer(s)
	issues << check_frame_single_writer(s)
	issues << check_nm_cluster_coherence(s)
	issues << check_telemetry_frames(s)
	issues << check_bus_dbcs(s)
	issues << check_routes(s, false)
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
	issues << check_dissolved_nodes(s)
	issues << check_partial_no_wiring(s)
	issues << check_routes(s, true)
	issues << check_signals_dissolved(s)
	issues << check_dbc_conformance(s)
	issues << check_route_dbc(s)
	issues << check_telemetry_frames(s)
	return issues
}

// check_partial_no_wiring: a dissolved node authors INTERNALS ONLY. If its
// ecu.toml declares bus wiring — a [bus.*], a [[signal]] with a bus endpoint, a
// [[frame]], or a [nm] — the generator appends it verbatim and it bypasses every
// dissolution check (e.g. an unowned extra transmitter defeats single-writer).
// The system owns all bus wiring + identity (REQ-TOPO-005).
fn check_partial_no_wiring(s System) []Issue {
	mut issues := []Issue{}
	for n in s.nodes {
		mut authored := []string{}
		if n.view.local_buses.len > 0 {
			authored << '[bus.*]'
		}
		// ANY [[signal]]/[[frame]] — even one whose bus endpoint has no matching
		// [bus.*] (produces/consumes miss those, but the generator prepends the
		// interface, activating the authored wiring).
		if n.view.authored_signals {
			authored << 'a [[signal]]'
		}
		if n.view.authored_frames {
			authored << 'a [[frame]]'
		}
		if n.view.has_nm {
			authored << 'a [nm]'
		}
		// a [[route]] in a partial is copied verbatim but never enters System.routes,
		// so check_routes never verifies its gateway/buses — an unchecked forward.
		if n.view.authored_routes {
			authored << 'a [[route]]'
		}
		if authored.len > 0 {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'node "${n.name}": authors bus wiring (${authored.join(", ")}) — a dissolved node is internals-only; the system owns the wiring + identity'
			}
		}
	}
	return issues
}

// check_dissolved_nodes: node-shape rules the generator relies on. Every node
// gets a generated [nm], so every node must be NM-allocated (REQ-TOPO-005) and
// its derived alive id (peers base + node) must land in the cluster range
// (REQ-TOPO-004). P1 emits wiring for ONE bus per node; a multi-bus (gateway)
// node is P2 — reject it now rather than silently wiring everything to bus[0].
fn check_dissolved_nodes(s System) []Issue {
	mut issues := []Issue{}
	for n in s.nodes {
		if !n.has_nm_alloc {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'node "${n.name}": system.toml must allocate an `nm` (the generator emits [nm] for every node)'
			}
		} else if n.nm > 0xff {
			// loom2v requires the NM node id in 0..255 (the generated [nm] node)
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-002'
				msg:      'node "${n.name}": nm 0x${n.nm.hex()} exceeds 0xff — the NM node id is 0..255'
			}
		}
		if n.buses.len != 1 {
			// a multi-bus node is only legal as a route GATEWAY (P2): its extra buses
			// exist to carry routes. A multi-bus node that gateways nothing would have
			// its non-primary buses silently unwired, so still reject that.
			if n.buses.len == 0 || !is_route_gateway(s, n.name) {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-006'
					msg:      'node "${n.name}": is on ${n.buses.len} buses but gateways no route — a multi-bus node must be a declared [[route]] gateway'
				}
				continue
			}
			// gateway: every bus it names must be declared (each carries a route or
			// its own signals); NM is scoped to the primary bus buses[0] below (a
			// per-bus-NM gateway is a later P2 item, docs/multi-node.md).
			mut seen_bus := map[string]bool{}
			for bn in n.buses {
				if seen_bus[bn] {
					// a duplicate would emit that [bus.*] table twice — reject before
					// generation rather than failing when ecucheck parses the output.
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-006'
						msg:      'node "${n.name}": bus "${bn}" is listed more than once in `buses`'
					}
				}
				seen_bus[bn] = true
				if _ := s.bus_by_name(bn) {
				} else {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-001'
						msg:      'node "${n.name}": bus "${bn}" is not declared in system.toml'
					}
				}
			}
			// P2a generates a PURE-routing gateway: its own [[signal]]/[[frame]] wiring
			// (for FBs it runs that read/write SYSTEM signals) is not emitted yet, so
			// such an FB would reference undeclared sig.*/port types. Reject until
			// gateway-local signal emission lands — the routes themselves ARE generated.
			// (Node-LOCAL io signals are fine; only system signals need the wiring.)
			for sig in s.signals {
				if sig.name in n.view.fb_reads || sig.name in n.view.fb_writes {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-006'
						msg:      'gateway "${n.name}" reads/writes system signal "${sig.name}" via an FB — a gateway that also produces/consumes its own signals is not generated yet (P2); in P2a a gateway may only route'
					}
				}
			}
			// NM runs inside the comm thread, on the TELEMETRY bus ([nm].bus is only a
			// manifest label, it does not move NM's tx — checks.v). So a gateway whose
			// primary bus has an NM cluster must run its telemetry (hence the comm
			// thread + NM) on that SAME bus, else its alive frames go to the wrong net.
			prim_iface := if b := s.bus_by_name(n.buses[0]) { b.interface } else { '' }
			if prim0 := s.bus_by_name(n.buses[0]) {
				if prim0.has_nm_cluster && n.view.has_telemetry && n.view.telem_bus != prim_iface {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-004'
						msg:      'gateway "${n.name}": NM cluster is on the primary bus "${n.buses[0]}" (${prim_iface}) but [telemetry].bus is "${n.view.telem_bus}" — NM runs on the telemetry bus, so they must be the same bus'
					}
				}
			}
			// a gateway carries a route, i.e. bus traffic — which needs a comm bridge.
			// A bare-metal target has no comm thread (loom2v rejects external signals
			// on bare-metal), so a bare-metal gateway cannot be built for its target.
			if n.view.is_baremetal {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-006'
					msg:      'gateway "${n.name}" is a bare-metal target — a route needs a comm bridge, which bare-metal has no runtime for (use a threadx or host target)'
				}
			}
			// the generator emits ONE NM instance, scoped to the primary bus buses[0].
			// A cluster on a SECONDARY bus would need a second NM instance (multi-instance
			// NM is a later P2 item) — until then the gateway would route/transmit on the
			// secondary network without participating in its sleep/wake. Reject it.
			for bn in n.buses[1..] {
				sb := s.bus_by_name(bn) or { continue }
				if sb.has_nm_cluster {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-004'
						msg:      'gateway "${n.name}": secondary bus "${bn}" declares an NM cluster, but the generator emits only ONE NM instance (on the primary bus "${n.buses[0]}") — a per-bus-NM gateway is a later P2 item'
					}
				}
			}
		}
		bus := s.bus_by_name(n.buses[0]) or {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-001'
				msg:      'node "${n.name}": bus "${n.buses[0]}" is not declared in system.toml'
			}
			continue
		}
		if bus.has_nm_cluster && n.has_nm_alloc {
			alive := bus.nm_peers_lo + n.nm
			if alive < bus.nm_peers_lo || alive > bus.nm_peers_hi {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-004'
					msg:      'node "${n.name}": derived alive id 0x${alive.hex()} (peers base + nm 0x${n.nm.hex()}) is outside the cluster range [0x${bus.nm_peers_lo.hex()},0x${bus.nm_peers_hi.hex()}]'
				}
			}
			// the generated [nm] only has a runtime on the threadx target with a
			// telemetry bus (loom2v injects host NM nowhere), so a host node with a
			// cluster gets a dead [nm] — its alive never transmits, traffic ungated.
			if !n.view.is_threadx || !n.view.has_telemetry {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-004'
					msg:      'node "${n.name}": is on an NM cluster but is not a threadx target with a [telemetry] bus — the generated [nm] would have no runtime'
				}
			} else if !node_has_external(s, n) {
				// even threadx + telemetry: loom2v runs NM ONLY inside the comm
				// thread, and emits that thread only when the node has a BRIDGE
				// (>=1 external signal / ISO-TP / route). Telemetry alone is not a
				// bridge, so a signal-less cluster member gets a [nm] with no comm
				// thread — its alive frames never transmit (dead NM), and its COM
				// tx is never NM-gated.
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-004'
					msg:      'node "${n.name}": is on an NM cluster but produces/consumes no system signal — loom2v emits NM only inside the comm thread, which needs a bridge (>=1 external signal); its NM would never transmit'
				}
			}
			// NM ids must fit a standard 11-bit CAN id: the FDCAN backend masks
			// (id & 0x7ff), so a range/alive above 0x7ff is silently truncated.
			if bus.nm_peers_hi > 0x7ff || alive > 0x7ff {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-004'
					msg:      'node "${n.name}": NM peer range/alive exceeds 0x7ff (11-bit CAN) — the FDCAN backend masks id & 0x7ff'
				}
			}
		}
	}
	return issues
}

// node_has_external: does this node produce or consume any system signal? loom2v
// turns on the comm thread (has_bridge) only for a node with >=1 external signal
// (P1 models ISO-TP / routes elsewhere). Telemetry alone is NOT a bridge.
fn node_has_external(s System, n Node) bool {
	for sig in s.signals {
		if sig.producer == n.name {
			return true
		}
	}
	for r in n.view.fb_reads {
		if _ := s.signal_by_name(r) {
			return true
		}
	}
	// a route gateway is external too: its comm thread runs the forwarder (it
	// receives on the source bus and transmits on the destination bus), so it
	// needs the bridge even with no FB of its own reading/writing a signal.
	return is_route_gateway(s, n.name)
}

// is_route_gateway reports whether `name` is the gateway of any declared route.
fn is_route_gateway(s System, name string) bool {
	for r in s.routes {
		if r.gateway == name {
			return true
		}
	}
	return false
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
	// a cross-node signal is declared EXACTLY ONCE — a duplicate makes
	// signal_by_name (consumers) disagree with generate_node (which emits a tx
	// per declaration) (REQ-TOPO-001).
	mut sig_seen := map[string]bool{}
	for sig in s.signals {
		if sig.name in sig_seen {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-001'
				msg:      'signal "${sig.name}" declared more than once — a cross-node signal is declared exactly once'
			}
		} else {
			sig_seen[sig.name] = true
		}
	}
	// DISSOLUTION lowers a system-scope signal into CAN wiring: sysgen emits the
	// node's [bus.canN] + [[signal]] + the DBC frame it rides. There is no SOME/IP
	// lowering yet — a node's eth wiring is still AUTHORED in its ecu.toml ([someip]
	// + [[frame]], as examples/system_full/nodes/tcu does). Reject the combination
	// HERE: skipping the DBC contract for a someip bus (its signals ride service
	// events, not frames) would otherwise let a dissolved someip signal pass the gate
	// and be lowered as a CAN frame with no DBC (REQ-TOPO-003).
	for sig in s.signals {
		b := s.bus_by_name(sig.bus) or { continue }
		if b.kind == 'someip' {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'signal "${sig.name}": bus "${sig.bus}" is kind = "someip" — SOME/IP wiring is not lowered from system.toml yet; author it in the node\'s ecu.toml ([someip] + [[frame]]) and declare the bus membership only'
			}
		}
	}
	mut frame_owner := map[string]string{} // (bus, frame) -> producer node
	mut frame_cycle := map[string]int{}    // (bus, frame) -> cycle_ms
	for sig in s.signals {
		// loom2v's external bridge serializes only ONE value field per DBC signal,
		// so a cross-node signal carries EXACTLY ONE field (a multi-field codec is
		// future work) of a KNOWN fixed scalar type (an unknown/heap type like
		// "string" would violate the no-runtime-heap invariant). REQ-TOPO-001.
		// loom2v serializes ONE value field per DBC signal and treats a `valid`
		// field as metadata (excluded from the wire, set true on RX). So the
		// supported shape is exactly one NON-`valid` value field of a fixed scalar
		// type (no u64/i64 — lossy through the f64 bridge), plus an optional
		// `valid` bool. REQ-TOPO-001.
		mut n_value := 0
		for fname, ftype in sig.fields {
			if fname == 'valid' {
				if ftype != 'bool' {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-001'
						msg:      'signal "${sig.name}": the `valid` field must be bool, not "${ftype}"'
					}
				}
				continue
			}
			n_value++
			if type_bits(ftype) == 0 {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-001'
					msg:      'signal "${sig.name}": field "${fname}" has unsupported type "${ftype}" (use a fixed scalar: bool/u8/i8/u16/i16/u32/i32/f32/f64)'
				}
			} else if ftype == 'u64' || ftype == 'i64' {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-001'
					msg:      'signal "${sig.name}": field "${fname}" is ${ftype} — 64-bit integers are lossy through the f64 bridge; use <=32-bit widths'
				}
			}
		}
		if n_value == 0 {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-001'
				msg:      'signal "${sig.name}": has no value field (a `valid` field alone is not serializable) — declare exactly one non-`valid` field'
			}
		} else if n_value > 1 {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-001'
				msg:      'signal "${sig.name}": has ${n_value} value fields — a cross-node signal carries exactly one (plus an optional `valid`)'
			}
		}
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
		// the producer must not ALSO read its own bus-published signal: sysgen
		// emits only the TX endpoint, so the FB and the COM bridge would both hold
		// the one SPSC TX channel (loom2v rejects a bus TX signal with any reader).
		if sig.name in p.view.fb_reads {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-001'
				msg:      'signal "${sig.name}": producer "${p.name}" also reads it — a bus-published signal has no local reader (use a separate local feedback signal)'
			}
		}
		if sig.bus !in p.buses {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-001'
				msg:      'signal "${sig.name}": producer "${p.name}" does not sit on its bus "${sig.bus}"'
			}
		}
		// the producer's FBs must write it EXACTLY ONCE — zero = nothing drives
		// the tx; two+ = two publishers to one SPSC channel (the ThreadX emitter
		// rejects that shape too) (REQ-TOPO-005).
		mut nwrite := 0
		for w in p.view.fb_writes {
			if w == sig.name {
				nwrite++
			}
		}
		if nwrite == 0 {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'signal "${sig.name}": producer "${p.name}" has no FB that writes it'
			}
		} else if nwrite > 1 {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-001'
				msg:      'signal "${sig.name}": producer "${p.name}" writes it from ${nwrite} FBs — a signal needs exactly one writer'
			}
		}
		// one producer per DBC frame, PER BUS (the same message name on two
		// separate buses/DBCs is fine): two signals in one frame from two nodes
		// contend for the PDU (REQ-TOPO-001). Same-frame signals must also agree
		// on tx cadence — sysgen emits one [[frame]] per PDU and loom2v keys frame
		// timing by message name, so conflicting cycle_ms silently overwrites.
		if sig.frame != '' {
			key := '${sig.bus}\x1f${sig.frame}'
			if prev := frame_owner[key] {
				if prev != sig.producer {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-001'
						msg:      'frame "${sig.frame}" on bus "${sig.bus}": carries signals from both "${prev}" and "${sig.producer}" — one frame owner per bus'
					}
				}
				eff := effective_cycle_ms(sig.cycle_ms)
				if frame_cycle[key] != 0 && eff != frame_cycle[key] {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-001'
						msg:      'frame "${sig.frame}" on bus "${sig.bus}": signals disagree on cycle (${frame_cycle[key]} vs ${eff} ms effective) — a frame has one cadence'
					}
				}
				if frame_cycle[key] == 0 {
					frame_cycle[key] = eff
				}
			} else {
				frame_owner[key] = sig.producer
				frame_cycle[key] = effective_cycle_ms(sig.cycle_ms)
			}
		}
		// reachability: does anyone read it? (a produced-but-unconsumed signal).
		// A reader must sit on the signal's bus — else sysgen emits its rx on the
		// wrong interface (the reader's sole bus, not sig.bus) (REQ-TOPO-001).
		mut consumed := false
		for n in s.nodes {
			if n.name == sig.producer || sig.name !in n.view.fb_reads {
				continue
			}
			consumed = true
			if sig.bus !in n.buses {
				// a cross-bus consumer is legal iff a SIGNAL route carries the signal
				// onto a bus it DOES sit on (the gateway re-encodes it there). Without
				// such a route the rx would land on the wrong interface (REQ-TOPO-001).
				mut routed := false
				for b in n.buses {
					if signal_routed_to(s, sig.name, b) {
						routed = true
						break
					}
				}
				if !routed {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-001'
						msg:      'signal "${sig.name}": consumer "${n.name}" reads it but is not on its bus "${sig.bus}" and no signal route carries it to a bus "${n.name}" sits on'
					}
				}
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
	// every FB read/write must reference a DECLARED system signal, and only the
	// declared producer may write it — else the generator emits a port to an
	// undeclared sig.<name> type (build fails despite a "gated" report), or wires
	// a second transmitter of the frame. P1 routes ALL cross-node signals through
	// system.toml (node-local signals are a future extension) (REQ-TOPO-001).
	for n in s.nodes {
		for w in n.view.fb_writes {
			if sig := s.signal_by_name(w) {
				if sig.producer != n.name {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-001'
						msg:      'node "${n.name}": FB writes "${w}" but its declared producer is "${sig.producer}" — only the producer may write a signal'
					}
				}
			} else if w !in n.view.local_signals {
				// a node-local signal (an io output, or a node-internal signal) is
				// the node's own — only a name that is neither system nor local errors.
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-001'
					msg:      'node "${n.name}": FB writes "${w}" which is neither a system signal nor a node-local (io) signal'
				}
			}
		}
		for r in n.view.fb_reads {
			if _ := s.signal_by_name(r) {
				continue
			}
			if r in n.view.local_signals {
				continue // a node-local (io) input — the node's own
			}
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-001'
				msg:      'node "${n.name}": FB reads "${r}" which is neither a system signal nor a node-local (io) signal'
			}
		}
		// a cross-node RX signal read from >1 partition = concurrent readers of the
		// one bus-to-partition SPSC IOC channel sysgen emits (a race). REQ-TOPO-001.
		for sig, parts in n.view.read_partitions {
			if parts.len > 1 && s.signal_by_name(sig) != none {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-001'
					msg:      'node "${n.name}": signal "${sig}" is read from ${parts.len} partitions (${parts.join(", ")}) — one bus-RX signal has a single reader partition'
				}
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
		// the CARRIER is an enum, not free text: every kind-aware check special-cases
		// the exact string 'someip', so a typo ("somepi") would silently fall back to
		// CAN behaviour — DBC required, membership by interface — instead of failing
		// here where the mistake is (REQ-TOPO-001).
		if b.kind !in ['can', 'someip'] {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-001'
				msg:      'bus "${b.name}": unknown kind "${b.kind}" — the carrier is "can" (DBC frames) or "someip" (a service)'
			}
		}
		// the contract fields follow the carrier: a `dbc` on a someip bus (or a
		// service/version on a CAN one) is read by nothing and would be silently
		// ignored — the same typo trap one level down.
		// the service IS a someip bus's contract — the id every member's receive
		// envelope gates on. Without it there is nothing for members to agree about,
		// and check_someip_membership would "match" them all at 0x0.
		if b.kind == 'someip' && !b.has_service {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'bus "${b.name}": kind = "someip" needs a `service` — it is the contract members are held to (a CAN bus has its `dbc`). 0x0000 is a legal id; the key must be PRESENT'
			}
		}
		// the SOME/IP header carries service as u16 and interface version as u8, so an
		// out-of-range value is not a big number, it is an impossible contract — and it
		// must fail even on a bus no node has joined yet (the u32 cast would wrap -1).
		if b.kind == 'someip' && !b.service_ok {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'bus "${b.name}": `service` is outside the SOME/IP service id range 0x0000..0xFFFF'
			}
		}
		if b.kind == 'someip' && !b.version_ok {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'bus "${b.name}": `version` is outside the SOME/IP interface version range 0..255'
			}
		}
		if b.kind == 'someip' && b.dbc != '' {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'bus "${b.name}": kind = "someip" carries a service, not DBC frames — remove `dbc = "${b.dbc}"` (it is never loaded)'
			}
		}
		if b.kind == 'can' && (b.has_service || b.has_version) {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-003'
				msg:      'bus "${b.name}": `service`/`version` describe a SOME/IP service — a CAN bus carries DBC frames (set kind = "someip" or remove them)'
			}
		}
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

// check_node_generatable runs the REAL loom2v on each node with its bus DBC, so a
// clean syscheck implies every node actually GENERATES — not just parses. loom2v
// enforces the whole family of target-dependent constraints the manual checks
// would otherwise each have to mirror (threadx comm bridge signal/id format, the
// single-local-partition rule, comm-owner priority, trace-setting limits, the
// telemetry-bus-exists rule, ISO-TP/routes). Shelling the generator keeps the gate
// EXACT (REQ-TOPO-005). Cross-node checks (identity, single-writer, telemetry
// ownership) stay separate — loom2v is per-node and cannot see a node's peers.
fn check_node_generatable(s System) []Issue {
	mut issues := []Issue{}
	for n in s.nodes {
		node_path := if os.is_abs_path(n.ecu) { n.ecu } else { os.join_path(s.dir, n.ecu) }
		if !os.exists(node_path) {
			continue // a missing/unloadable node is already reported by load_nodes
		}
		// the node's bus DBC — loom2v resolves its external signals against it. Pick
		// the ACTIVE bus (its telemetry/signal bus), NOT buses[0]: a valid P1 node may
		// list an unused diagnostic bus first, and resolving signals against that
		// unrelated DBC would wrongly report the node non-generatable.
		mut active_iface := n.view.telem_bus
		if active_iface == '' {
			for iface, sigs in n.view.produces {
				if sigs.len > 0 {
					active_iface = iface
					break
				}
			}
		}
		if active_iface == '' {
			for iface, sigs in n.view.consumes {
				if sigs.len > 0 {
					active_iface = iface
					break
				}
			}
		}
		mut dbc := ''
		if active_iface != '' {
			if b := s.bus_by_interface(active_iface) {
				dbc = b.dbc
			}
		} else if n.buses.len > 0 {
			if b := s.bus_by_name(n.buses[0]) {
				dbc = b.dbc
			}
		}
		mut dbc_path := ''
		if dbc != '' {
			dbc_path = if os.is_abs_path(dbc) { dbc } else { os.join_path(s.dir, dbc) }
		}
		for e in loom2v_errors(node_path, dbc_path) {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'node "${n.name}" is not generatable: ${e}'
			}
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
		// a node offers ONE SOME/IP service: its ecu.toml has a single [someip] block,
		// so claiming two someip buses would validate both against the same endpoint
		// and generate one service for two contracts (REQ-TOPO-005).
		mut someip_claims := []string{}
		for bname in n.buses {
			b := s.bus_by_name(bname) or { continue }
			if b.kind == 'someip' {
				someip_claims << bname
			}
		}
		if someip_claims.len > 1 {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'node "${n.name}": claims ${someip_claims.len} someip buses (${someip_claims.join(', ')}) — a node has one [someip] endpoint, so it offers one service'
			}
		}
		for bname in n.buses {
			b := s.bus_by_name(bname) or {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-001'
					msg:      'node "${n.name}": bus "${bname}" is not declared in system.toml'
				}
				continue
			}
			if b.kind == 'someip' {
				issues << check_someip_membership(n, b)
				continue
			}
			if b.interface !in n.view.local_buses {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-005'
					msg:      'node "${n.name}": claims bus "${bname}" but its ecu.toml has no [bus.${b.interface}] interface (declares ${n.view.local_buses})'
				}
			} else if (n.view.local_bus_fd[b.interface] or { false }) != b.fd {
				// the node's local [bus.X].fd must match the system bus contract, or its
				// generated driver opens the channel in a different CAN mode than its
				// peers (classic vs FD are not interoperable on one wire) — REQ-TOPO-005.
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-005'
					msg:      'node "${n.name}": [bus.${b.interface}].fd = ${n.view.local_bus_fd[b.interface] or {
						false
					}} disagrees with system bus "${bname}" fd = ${b.fd} — one CAN mode per wire'
				}
			}
		}
		// the reverse: a local interface that matches a system bus must be CLAIMED
		// in `buses`, or producers_on/consumers_on (which filter on `buses`) drop
		// this node's traffic silently — its collisions vanish from the checks.
		// EXPLICIT MEMBERSHIP (someip): the ONE interface a node joins a someip bus with
		// is its own address, which no system bus's `interface` matches — that endpoint's
		// contract is the membership claim (checked above), not an interface match. Scope
		// the exemption to exactly that interface: a node on a someip bus that ALSO opens
		// some other undeclared interface still has untracked traffic there.
		someip_endpoint := someip_endpoint_of(s, n)
		for iface in n.view.local_buses {
			if iface != '' && iface == someip_endpoint && s.bus_by_interface(iface) == none {
				continue
			}
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
						msg:      'node "${n.name}": opens interface [bus.${iface}] not declared by any system bus, yet carries ${kinds.join('/')} on it — that traffic has no system contract and is never checked for writers, reachability, or frame ownership'
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
	// what the MEMBERS of a someip bus owe each other (reciprocal peers, one address
	// each, agreed event ids) — membership alone does not connect two eth nodes.
	for b in s.buses {
		if b.kind == 'someip' {
			issues << check_someip_bus(s, b)
		}
	}
	return issues
}

// EXPLICIT MEMBERSHIP (someip). CAN matches a node to a bus by shared `interface`
// — every node literally says "can0". Each eth node has its OWN address (tcu
// 192.168.0.51, sysnode .50), so interface equality cannot express "on the same
// segment": a someip bus is joined by NAMING it in `buses`, and the system declares
// who is on what. What the node must then have is a local SOME/IP ENDPOINT
// ([someip].bus -> one of its [bus.*]) whose service contract IS the one the system
// bus declares: the generated receive envelope drops a foreign service/version, so
// members that disagree are silently deaf to each other (REQ-TOPO-005).
fn check_someip_membership(n Node, b Bus) []Issue {
	mut issues := []Issue{}
	if !n.view.has_someip {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-005'
			msg:      'node "${n.name}": claims someip bus "${b.name}" but its ecu.toml declares no [someip] endpoint (bus + service)'
		}
		return issues
	}
	if n.view.someip_iface !in n.view.local_buses {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-005'
			msg:      'node "${n.name}": [someip].bus resolves to "${n.view.someip_iface}", which is not one of its [bus.*] interfaces (declares ${n.view.local_buses})'
		}
	}
	if n.view.someip_service != b.service {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-005'
			msg:      'node "${n.name}": offers SOME/IP service 0x${n.view.someip_service.hex()} but system bus "${b.name}" declares 0x${b.service.hex()} — the receive envelope drops a foreign service'
		}
	}
	if n.view.someip_version != b.version {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-005'
			msg:      'node "${n.name}": offers SOME/IP interface version ${n.view.someip_version} but system bus "${b.name}" declares ${b.version} — one version per service contract'
		}
	}
	return issues
}

// check_someip_bus enforces what a SOME/IP bus's MEMBERS owe each other — the part
// a shared bus name does not give you. There is no service discovery on the target:
// the generated bridge sends only TO its configured static peer and accepts only
// FROM it, and it dispatches a received payload on the EVENT id. So membership alone
// never means "connected", and syscheck must not credit reachability on it.
//
//   - one address per member: two endpoints resolving to the same IP bring up the
//     same address on one segment (ARP conflict, nondeterministic delivery);
//   - the peers must be RECIPROCAL: each member's `peer` is the other's
//     `<address>:<port>`. A static peer is point-to-point, so a bus with >2 members
//     cannot be wired at all today — say that instead of generating deaf nodes;
//   - the EVENT ids must agree: a producer sending "BenchLoad" as 0x8001 and a
//     consumer expecting 0x8002 match by NAME and never talk (REQ-TOPO-005).
fn check_someip_bus(s System, bus Bus) []Issue {
	mut issues := []Issue{}
	mut members := []Node{}
	for n in s.nodes {
		if bus.name in n.buses && n.view.has_someip {
			members << n
		}
	}
	// one endpoint address per member
	mut addr_of := map[string]string{} // iface -> the node that already claimed it
	for n in members {
		if n.view.someip_iface == '' {
			continue
		}
		if prev := addr_of[canon_addr(n.view.someip_iface)] {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'bus "${bus.name}": nodes "${prev}" and "${n.name}" both use endpoint address "${n.view.someip_iface}" — one address per node on a segment'
			}
		} else {
			addr_of[canon_addr(n.view.someip_iface)] = n.name
		}
	}
	if members.len < 2 {
		return issues // a single member has no peer on-system to be reciprocal with
	}
	if members.len > 2 {
		issues << Issue{
			severity: .error
			req:      'REQ-TOPO-005'
			msg:      'bus "${bus.name}": ${members.len} members (${members.map(it.name).join(', ')}) — a static SOME/IP peer is point-to-point, so a bus carries at most 2 members until service discovery exists'
		}
		return issues
	}
	a, b := members[0], members[1]
	for x, y in {
		a.name: b
		b.name: a
	} {
		me := if x == a.name { a } else { b }
		want := '${canon_addr(y.view.someip_iface)}:${y.view.someip_port}'
		if canon_endpoint(me.view.someip_peer) != want {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-005'
				msg:      'node "${me.name}": [someip].peer is "${me.view.someip_peer}" but bus "${bus.name}" puts it with "${y.name}" at "${want}" — the bridge talks ONLY to its static peer, so these two never exchange a datagram'
			}
		}
	}
	// the EVENT each shared signal rides must be the same on both ends
	prod := producers_on(s, bus)
	cons := consumers_on(s, bus)
	for sig, pnodes in prod {
		cnodes := cons[sig] or { continue }
		for pn in pnodes {
			for cn in cnodes {
				p := node_named(s, pn) or { continue }
				c := node_named(s, cn) or { continue }
				pid := p.view.sig_frame_id['${p.view.someip_iface}|${sig}'] or {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-005'
						msg:      'bus "${bus.name}": node "${pn}" transmits signal "${sig}" but binds it to no [[frame]] id — a SOME/IP event needs the id the receiver dispatches on'
					}
					continue
				}
				cid := c.view.sig_frame_id['${c.view.someip_iface}|${sig}'] or {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-005'
						msg:      'bus "${bus.name}": node "${cn}" receives signal "${sig}" but binds it to no [[frame]] id — a SOME/IP event needs the id the receiver dispatches on'
					}
					continue
				}
				if pid != cid {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-005'
						msg:      'bus "${bus.name}": signal "${sig}" is event 0x${pid.hex()} on "${pn}" but 0x${cid.hex()} on "${cn}" — the receive bridge dispatches on the event id, so the value never arrives'
					}
					continue
				}
				// the same event id is not enough: the receiver enforces its OWN payload
				// length and unpacks its OWN derived layout, so a difference in the
				// signal's fields, the frame's signal list (= packing order), or its E2E
				// parameters is a counted drop or silently misdecoded data. The layout is
				// DERIVED from these inputs by one generator, so comparing the inputs is
				// exact without duplicating the packing rules here.
				pf := p.view.sig_fields['${p.view.someip_iface}|${sig}'] or { '' }
				cf := c.view.sig_fields['${c.view.someip_iface}|${sig}'] or { '' }
				if pf != cf {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-005'
						msg:      'bus "${bus.name}": signal "${sig}" has fields {${pf}} on "${pn}" but {${cf}} on "${cn}" — the receiver unpacks its own layout, so the payload is misdecoded'
					}
				}
				pp := p.view.sig_payload['${p.view.someip_iface}|${sig}'] or { '' }
				cp := c.view.sig_payload['${c.view.someip_iface}|${sig}'] or { '' }
				if pp != cp {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-005'
						msg:      'bus "${bus.name}": event 0x${pid.hex()} carrying "${sig}" is "${pp}" on "${pn}" but "${cp}" on "${cn}" — one event, one payload contract (signal order sets the packing; E2E must match or every frame fails its check)'
					}
				}
			}
		}
	}
	return issues
}

// canon_addr canonicalizes a dotted-quad address so two spellings of ONE address
// compare equal. ecucheck accepts "192.168.000.050" and "192.168.0.50" alike and the
// generated endpoints resolve to the same numeric address, so a raw-string compare
// would let the duplicate-address and reciprocal-peer checks pass a system whose two
// members are actually the same host. Anything that is not a dotted quad is returned
// unchanged (a hostname or an already-odd value stays comparable to itself).
fn canon_addr(a string) string {
	parts := a.split('.')
	if parts.len != 4 {
		return a
	}
	mut out := []string{cap: 4}
	for p in parts {
		if p == '' || p.len > 3 {
			return a
		}
		for c in p {
			if c < `0` || c > `9` {
				return a
			}
		}
		n := p.u32()
		if n > 255 {
			return a
		}
		out << n.str()
	}
	return out.join('.')
}

// canon_endpoint canonicalizes an "<address>:<port>" peer spelling the same way.
fn canon_endpoint(e string) string {
	i := e.last_index(':') or { return canon_addr(e) }
	return '${canon_addr(e[..i])}:${e[i + 1..]}'
}

fn node_named(s System, name string) ?Node {
	for n in s.nodes {
		if n.name == name {
			return n
		}
	}
	return none
}

// someip_endpoint_of returns the node's local SOME/IP endpoint interface IF it
// claims a someip bus, else '' — an endpoint only earns its membership exemption
// through an actual claim.
fn someip_endpoint_of(s System, n Node) string {
	for bname in n.buses {
		b := s.bus_by_name(bname) or { continue }
		if b.kind == 'someip' {
			return n.view.someip_iface
		}
	}
	return ''
}

// node_iface_on returns the LOCAL interface a node carries a system bus's traffic
// on, or none if it is not a member. CAN: the bus's shared interface name, spelled
// the same on every node. someip: the node's OWN [someip] endpoint address — under
// explicit membership the system bus and the node's interface deliberately differ,
// so ownership has to resolve through the endpoint or produces/consumes come back
// empty and every duplicate writer and orphaned consumer on the bus passes silently.
fn node_iface_on(n Node, bus Bus) ?string {
	if bus.name !in n.buses {
		return none
	}
	if bus.kind == 'someip' {
		if n.view.someip_iface == '' {
			return none
		}
		return n.view.someip_iface
	}
	return bus.interface
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
// check_frame_single_writer is defined in telem.v (it resolves produced signals to
// their DBC messages, so it needs candb).

// producers_on returns, for a system bus, a map signal -> [node names that
// transmit it on that bus]. A node produces on bus B the signals its ecu.toml
// sends to B's interface.
fn producers_on(s System, bus Bus) map[string][]string {
	mut prod := map[string][]string{}
	for n in s.nodes {
		iface := node_iface_on(n, bus) or { continue }
		for sig in n.view.produces[iface] {
			prod[sig] << n.name
		}
	}
	return prod
}

fn consumers_on(s System, bus Bus) map[string][]string {
	mut cons := map[string][]string{}
	for n in s.nodes {
		iface := node_iface_on(n, bus) or { continue }
		for sig in n.view.consumes[iface] {
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
					msg:      'bus "${bus.name}": signal "${sig}" transmitted by ${nodes.len} nodes (${nodes.join(', ')}) — exactly one writer per bus'
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
					msg:      'bus "${bus.name}": signal "${sig}" consumed by ${nodes.join(', ')} but no node transmits it here (missing producer or route)'
				}
			}
		}
		// a produced cross-node signal with NO receiver is an ERROR: REQ-TOPO-001
		// requires every transmitted signal to be received by at least one node, so
		// a typo or missing consumer that silently drops all data must fail the gate.
		for sig, nodes in prod {
			if sig !in cons && !signal_routed_from(s, sig, bus.name) {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-001'
					msg:      'bus "${bus.name}": signal "${sig}" transmitted by ${nodes.join(', ')} but no node receives it (REQ-TOPO-001: every cross-node signal needs >=1 receiver)'
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
		// the ECU's ACTUAL [[isotp]] rx_id/tx_id are the on-wire diagnostic ids
		// (loom2v emits them, id 0 INCLUDED); system.toml `diag` is only the
		// allocation. Register the real ids in the SAME map so two nodes physically
		// using one diagnostic CAN id collide even when their diag allocations differ.
		mut isotp_ids := []u32{}
		for c in n.view.isotp_conns {
			isotp_ids << c.rx_id
			isotp_ids << c.tx_id
		}
		for iid in isotp_ids {
			if prev := diag_seen[iid] {
				if prev == n.name {
					continue // the node's own diag allocation == its isotp id (expected)
				}
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-002'
					msg:      'node "${n.name}": [[isotp]] diagnostic id 0x${iid.hex()} collides with an id already used by "${prev}"'
				}
			} else {
				diag_seen[iid] = n.name
			}
		}
		// trace id uniqueness by DECLARED presence — 0 is a valid trace id, so two
		// nodes explicitly allocated `trace = 0` are indistinguishable in the manifest
		// (an omitted `trace` is not a participant).
		if n.has_trace {
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
			// the threadx FDCAN backend masks id & 0x7ff, so an active alive id (or
			// peer range) above 0x7ff is silently truncated — e.g. 0x811 goes out as
			// 0x11 and collides. Validate the 11-bit limit before trusting the id.
			if n.view.alive > 0x7ff || n.view.peers_hi > 0x7ff {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-004'
					msg:      'bus "${bus.name}": node "${n.name}" active NM alive 0x${n.view.alive.hex()} / peer range hi 0x${n.view.peers_hi.hex()} exceeds 0x7ff (11-bit CAN) — the FDCAN backend masks id & 0x7ff'
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
fn check_routes(s System, dissolved bool) []Issue {
	mut issues := []Issue{}
	for r in s.routes {
		// routes are lowered ONLY in the dissolution (sysgen reads system.toml
		// [[signal]]s and emits each gateway's forwarder). A COMPOSED system
		// (validate_system) never runs sysgen, so a route there would validate clean
		// with no forwarder at runtime — reject every route in that model.
		if !dissolved {
			kind := if r.signal != '' { 'signal' } else { 'frame' }
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-006'
				msg:      'route on "${r.gateway}" (${kind} "${r.signal}${r.frame}", ${r.from} -> ${r.to}): cross-bus routing is only generated in the dissolution model (system.toml [[signal]]); a composed system does not lower routes'
			}
		}
		// FRAME (raw-PDU) routes ARE generated now (P2b): sysgen lowers a raw forwarder
		// and check_route_dbc's full-contract compare (REQ-TOPO-007) gates it. The
		// well-formedness + single-writer + cycle checks below apply to both kinds.
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
		// a route lowers to a CAN forwarder (raw PDU copy or DBC re-encode). Crossing a
		// someip bus is the eth GATEWAY, which is a later phase (docs/someip.md P3) —
		// say so here, or the route falls into the DBC checks and fails as "destination
		// bus has no `dbc`", which reads like a missing file rather than a missing feature.
		for b in [r.from, r.to] {
			sb := s.bus_by_name(b) or { continue }
			if sb.kind == 'someip' {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-006'
					msg:      'route on "${r.gateway}": bus "${b}" is kind = "someip" — routing across a SOME/IP bus is not generated yet (the CAN<->SOME/IP gateway is a later phase)'
				}
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
		// a SIGNAL route carries a DECLARED, typed system signal from the bus that
		// actually produces it. Without the [[signal]] there is no field contract to
		// check against either DBC; without a producer on `from` the gateway would
		// decode the wrong source contract (both slip past reachability, which only
		// fires when a cross-bus FB consumer needs the route).
		if dissolved && r.signal != '' {
			if _ := s.signal_by_name(r.signal) {
			} else {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-006'
					msg:      'route on "${r.gateway}": "${r.signal}" is not a declared system [[signal]] — a signal route carries a typed system signal'
				}
			}
			if r.from != '' && !signal_produced_on(s, r.signal, r.from) {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-006'
					msg:      'route on "${r.gateway}": signal "${r.signal}" is not produced on its source bus "${r.from}" — the gateway would decode the wrong contract'
				}
			}
		}
		// REQ-TOPO-012: a signal route makes the gateway the SOLE on-wire writer of
		// the routed signal on the destination bus (the routed IOC/xioc cell is
		// single-writer). Reject a gateway-local (or any node-on-`to`) FB that also
		// writes it — that would be a second producer of the routed value.
		if r.signal != '' && r.to != '' {
			for n in s.nodes {
				if r.to in n.buses && r.signal in n.view.fb_writes {
					issues << Issue{
						severity: .error
						req:      'REQ-TOPO-012'
						msg:      'route on "${r.gateway}": signal "${r.signal}" routed to bus "${r.to}" is also written by an FB on node "${n.name}" — a routed cell has exactly one writer (the route)'
					}
				}
			}
			// REQ-TOPO-012 (frame ownership): the route makes the gateway transmit the
			// destination FRAME (the DBC message that carries the routed signal on `to`).
			// If ANOTHER node already produces a system signal that maps to that SAME
			// frame on `to`, the gateway + that node both transmit one PDU — reject it.
			if to := s.bus_by_name(r.to) {
				if dst_frame := dbc_frame_of(s, to, r.signal) {
					for ss in s.signals {
						if ss.bus != r.to || ss.name == r.signal {
							continue
						}
						of := dbc_frame_of(s, to, ss.name) or { continue }
						if of == dst_frame {
							issues << Issue{
								severity: .error
								req:      'REQ-TOPO-012'
								msg:      'route on "${r.gateway}": routed signal "${r.signal}" re-encodes into frame "${dst_frame}" on bus "${r.to}", which node "${ss.producer}" already transmits (signal "${ss.name}") — one on-wire writer per frame'
							}
						}
					}
				}
			}
		}
		// REQ-TOPO-012 (frame route): forwarding a frame onto `to` makes the gateway an
		// on-wire transmitter of that PDU. Reject any OTHER node on `to` that already
		// transmits it — a node producing a system signal mapping to the same frame on
		// `to` would collide with the forward.
		if r.frame != '' && r.to != '' {
			if to := s.bus_by_name(r.to) {
				rident := dbc_frame_ident(s, to, r.frame) or { '' }
				if rident != '' {
					for ss in s.signals {
						if ss.bus != r.to {
							continue
						}
						// compare ON-WIRE identity (id:ext), not the message name — a
						// producer whose frame shares the routed frame's CAN id collides.
						sident := dbc_sig_frame_ident(s, to, ss.name) or { continue }
						if sident == rident {
							issues << Issue{
								severity: .error
								req:      'REQ-TOPO-012'
								msg:      'frame route on "${r.gateway}": forwarded frame "${r.frame}" onto bus "${r.to}" shares its CAN id with a frame node "${ss.producer}" already transmits (signal "${ss.name}") — one on-wire writer per frame'
							}
						}
					}
				}
			}
		}
	}
	// REQ-TOPO-012 (cont.): two routes may not carry the same signal onto the same
	// destination bus — the second would be a second writer of that cell.
	mut routed_dest := map[string]string{} // "signal|to" -> first gateway
	// ...and one gateway OWNS each destination (bus, frame): a DIFFERENT gateway
	// routing into the same DBC message is PDU contention (two on-wire transmitters).
	// The SAME gateway composing several routed signals into one frame is fine.
	mut frame_owner := map[string]string{} // "ident|to" -> owning gateway
	mut raw_frame_dests := map[string]bool{} // "ident|to" owned by a RAW route (sole writer)
	for r in s.routes {
		if r.to == '' {
			continue
		}
		if r.signal != '' {
			key := '${r.signal}|${r.to}'
			if prev := routed_dest[key] {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-012'
					msg:      'signal "${r.signal}" is routed onto bus "${r.to}" by two routes (gateways "${prev}" and "${r.gateway}") — one writer per routed cell'
				}
			} else {
				routed_dest[key] = r.gateway
			}
		}
		to := s.bus_by_name(r.to) or { continue }
		// the destination frame a route makes the gateway transmit: for a frame route it
		// IS the forwarded frame; for a signal route it is the DBC message that carries
		// the routed signal on `to`. Key the owner by the frame's ON-WIRE identity
		// (id:ext), not its name.
		dst_frame := if r.frame != '' { r.frame } else { dbc_frame_of(s, to, r.signal) or {
			continue
		} }
		ident := dbc_frame_ident(s, to, dst_frame) or { continue }
		fkey := '${ident}|${r.to}'
		// A RAW frame route is the SOLE writer of the PDU — unlike composing signal
		// routes, it does not share the frame. So it collides with ANY other route onto
		// that identity, INCLUDING one from the same gateway (two independent forwarders,
		// or a raw route mixed with a signal route). Only multiple SIGNAL routes from ONE
		// gateway legitimately compose the frame.
		if prev := frame_owner[fkey] {
			raw_conflict := r.frame != '' || fkey in raw_frame_dests
			if prev != r.gateway || raw_conflict {
				issues << Issue{
					severity: .error
					req:      'REQ-TOPO-012'
					msg:      'destination frame "${dst_frame}" on bus "${r.to}" has two on-wire writers (gateways "${prev}" and "${r.gateway}"${if raw_conflict { ' — a raw frame route is a sole writer, it cannot share a frame' } else { '' }})'
				}
			}
		} else {
			frame_owner[fkey] = r.gateway
			if r.frame != '' {
				raw_frame_dests[fkey] = true
			}
		}
	}
	issues << check_route_cycles(s)
	return issues
}

// check_route_cycles: REQ-TOPO-011. A routed value that re-enters a bus it already
// traversed recirculates forever (each gateway re-emits + re-protects it). Build a
// per-signal directed graph of bus -> bus route edges and reject any cycle. Frame
// routes use their frame name as the key (a raw forward keeps the same frame), so
// frame and signal cycles are both caught.
fn check_route_cycles(s System) []Issue {
	mut issues := []Issue{}
	// group route edges (from_bus -> to_bus) by the carried entity (signal or frame)
	mut edges := map[string][][]string{} // entity -> list of [from, to]
	for r in s.routes {
		if r.from == '' || r.to == '' {
			continue
		}
		ent := if r.signal != '' { 'sig:${r.signal}' } else { 'frm:${r.frame}' }
		edges[ent] << [r.from, r.to]
	}
	for ent, es in edges {
		if graph_has_cycle(es) {
			issues << Issue{
				severity: .error
				req:      'REQ-TOPO-011'
				msg:      'routes for "${ent}" form a bus cycle — a routed value would recirculate forever (a firewall allow-list does not stop it)'
			}
		}
	}
	return issues
}

// graph_has_cycle detects a directed cycle in edges given as [from, to] pairs
// (DFS with a visiting/visited colouring over the node set the edges span).
fn graph_has_cycle(es [][]string) bool {
	mut adj := map[string][]string{}
	mut nodes := map[string]bool{}
	for e in es {
		adj[e[0]] << e[1]
		nodes[e[0]] = true
		nodes[e[1]] = true
	}
	mut state := map[string]int{} // 0/absent = unvisited, 1 = visiting, 2 = done
	for n, _ in nodes {
		if state[n] == 0 && dfs_cycle(n, adj, mut state) {
			return true
		}
	}
	return false
}

fn dfs_cycle(n string, adj map[string][]string, mut state map[string]int) bool {
	state[n] = 1
	for m in adj[n] or { []string{} } {
		if state[m] == 1 {
			return true // back-edge to a node on the current DFS stack
		}
		if state[m] == 0 && dfs_cycle(m, adj, mut state) {
			return true
		}
	}
	state[n] = 2
	return false
}

// signal_routed_to reports whether a route carries `sig` INTO `bus` from a source
// bus that ACTUALLY PRODUCES it — only then does the gateway have a value to
// forward, so only then is a cross-bus consumer on `bus` satisfied (REQ-TOPO-001/
// 006). A SIGNAL route names the signal directly; a FRAME (raw-PDU) route carries
// EVERY signal of its frame unchanged, so it satisfies `sig` when the routed frame
// (per the dest DBC) contains it and `sig` is produced on the source bus.
fn signal_routed_to(s System, sig string, bus string) bool {
	for r in s.routes {
		if r.to != bus {
			continue
		}
		if r.signal == sig {
			if signal_produced_on(s, sig, r.from) {
				return true
			}
		} else if r.frame != '' {
			to := s.bus_by_name(bus) or { continue }
			if dbc_frame_contains(s, to, r.frame, sig) && signal_produced_on(s, sig, r.from) {
				return true
			}
		}
	}
	return false
}

// dbc_frame_contains reports whether the DBC message named `frame` on `bus` carries
// an SG_ named `sig` — used to resolve which signals a raw frame route carries.
fn dbc_frame_contains(s System, bus Bus, frame string, sig string) bool {
	if bus.dbc == '' {
		return false
	}
	path := if os.is_abs_path(bus.dbc) { bus.dbc } else { os.join_path(s.dir, bus.dbc) }
	db := candb.load_dbc_file(path) or { return false }
	for m in db.messages {
		if m.name != frame {
			continue
		}
		for sg in m.signals {
			if sg.name == sig {
				return true
			}
		}
	}
	return false
}

// signal_produced_on: is `sig` produced on bus `bus`? Handles both models — the
// dissolved one (a system [[signal]] declared with that name + bus) and the
// authored one (a node on the bus whose view.produces, keyed by interface, lists it).
// NOTE (single-hop): this recognises only DIRECT producers, not a route INTO `bus`
// as production. So a multi-hop chain A->B->C is conservatively REJECTED (the B->C
// route sees no producer on B) — never wrongly accepted. Transitive multi-hop
// reachability is a P2b+ item; the cycle graph already spans gateways for -011.
fn signal_produced_on(s System, sig string, bus string) bool {
	for ss in s.signals {
		if ss.name == sig && ss.bus == bus {
			return true
		}
	}
	b := s.bus_by_name(bus) or { return false }
	for n in s.nodes {
		if bus in n.buses && sig in (n.view.produces[b.interface] or { []string{} }) {
			return true
		}
	}
	return false
}

// dbc_frame_of returns the DBC message on `bus` that carries `sig` as an SG_, or
// none if the bus has no DBC, the DBC won't load, or `sig` is absent / ambiguous
// (in >1 frame — sysgen's frame_of_signal rejects that; here we just decline to
// pick one). Used to resolve the destination frame for a route's ownership check.
fn dbc_frame_of(s System, bus Bus, sig string) ?string {
	if bus.dbc == '' {
		return none
	}
	path := if os.is_abs_path(bus.dbc) { bus.dbc } else { os.join_path(s.dir, bus.dbc) }
	db := candb.load_dbc_file(path) or { return none }
	mut hit := ?string(none)
	for m in db.messages {
		for sg in m.signals {
			if sg.name == sig {
				if hit != none {
					return none // ambiguous
				}
				hit = m.name
				break
			}
		}
	}
	return hit
}

// dbc_frame_ident returns a stable "id:ext" key for the DBC message named `frame`
// on `bus` — its ON-WIRE identity. Ownership must compare CAN identity, not the
// message NAME: candb accepts two differently-named BO_ at one CAN id, so a name
// compare would miss a genuine two-writer collision on that id.
fn dbc_frame_ident(s System, bus Bus, frame string) ?string {
	if bus.dbc == '' {
		return none
	}
	path := if os.is_abs_path(bus.dbc) { bus.dbc } else { os.join_path(s.dir, bus.dbc) }
	db := candb.load_dbc_file(path) or { return none }
	for m in db.messages {
		if m.name == frame {
			return '${m.id}:${m.ext}'
		}
	}
	return none
}

// dbc_sig_frame_ident resolves the frame carrying `sig` on `bus` to its "id:ext".
fn dbc_sig_frame_ident(s System, bus Bus, sig string) ?string {
	fr := dbc_frame_of(s, bus, sig)?
	return dbc_frame_ident(s, bus, fr)
}

// signal_consumed_on: does a node on `bus` consume `sig`? Dissolved = an FB read;
// authored = view.consumes (keyed by interface).
fn signal_consumed_on(s System, sig string, bus string) bool {
	b := s.bus_by_name(bus) or { return false }
	for n in s.nodes {
		if bus !in n.buses {
			continue
		}
		if sig in n.view.fb_reads {
			return true
		}
		if sig in (n.view.consumes[b.interface] or { []string{} }) {
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
		if signal_consumed_on(s, sig, r.to) {
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
