module sysmodel

import os
import toml

// REQ-TOPO-005 is method = "analysis" (the system-sourced-generation architecture,
// argued in docs/multi-node.md) — these validator tests exercise cross-node checks,
// not that generation analysis, so they must NOT claim to verify it by test.
// @verifies REQ-TOPO-001, REQ-TOPO-002, REQ-TOPO-004, REQ-TOPO-006, REQ-TOPO-011, REQ-TOPO-012

fn errs(issues []Issue) []string {
	mut out := []string{}
	for i in issues {
		if i.severity == .error {
			out << i.msg
		}
	}
	return out
}

fn reqs_of(issues []Issue, sev Severity) []string {
	mut out := []string{}
	for i in issues {
		if i.severity == sev {
			out << i.req
		}
	}
	return out
}

// a clean two-node/one-bus system: sysnode produces Speed, domain consumes it;
// domain produces Rpm, sysnode consumes it. Distinct identities, same cluster.
fn clean_system() System {
	return System{
		buses: [Bus{
			name:      'compute'
			interface: 'can0'
		}]
		nodes: [
			Node{
				name:         'sysnode'
				buses:        ['compute']
				nm:           0x11
				has_nm_alloc: true
				nm_alloc_ok:  true
				trace:        1
				has_trace:    true
				view:         NodeView{
					produces:    {
						'can0': ['Speed']
					}
					consumes:    {
						'can0': ['Rpm']
					}
					has_nm:      true
					nm_enabled:  true
					nm_node:     0x11
					has_nm_node: true
					nm_node_ok:  true
					alive:       0x511
					has_alive:   true
					peers_lo:    0x500
					peers_hi:    0x53f
					local_buses: ['can0']
				}
			},
			Node{
				name:         'domain'
				buses:        ['compute']
				nm:           0x13
				has_nm_alloc: true
				nm_alloc_ok:  true
				trace:        2
				has_trace:    true
				view:         NodeView{
					produces:    {
						'can0': ['Rpm']
					}
					consumes:    {
						'can0': ['Speed']
					}
					has_nm:      true
					nm_enabled:  true
					nm_node:     0x13
					has_nm_node: true
					nm_node_ok:  true
					alive:       0x513
					has_alive:   true
					peers_lo:    0x500
					peers_hi:    0x53f
					local_buses: ['can0']
				}
			},
		]
	}
}

fn test_clean_system_has_no_errors() {
	issues := validate_system(clean_system())
	assert errs(issues).len == 0, 'clean system flagged: ${errs(issues)}'
}

// REQ-TOPO-001: two nodes transmitting the same signal on one bus is a wire
// collision (the real bug the bench h735/h755 demos would hit sharing "Workload").
fn test_two_writers_same_bus_is_error() {
	mut s := clean_system()
	// make domain ALSO transmit Speed
	s.nodes[1].view.produces['can0'] = ['Rpm', 'Speed']
	issues := validate_system(s)
	e := errs(issues)
	assert e.len == 1, 'expected one collision, got ${e}'
	assert e[0].contains('Speed'), e[0]
	assert e[0].contains('transmitted by 2 nodes'), e[0]
	assert 'REQ-TOPO-001' in reqs_of(issues, .error)
}

// REQ-TOPO-001: a consumer with no producer on its bus (and no route) is an error.
fn test_consumer_without_producer_is_error() {
	mut s := clean_system()
	// domain consumes Torque that nobody transmits
	s.nodes[1].view.consumes['can0'] = ['Speed', 'Torque']
	issues := validate_system(s)
	e := errs(issues)
	assert e.any(it.contains('Torque') && it.contains('no node transmits')), e.str()
}

// REQ-TOPO-001: a produced cross-node signal with no receiver is an ERROR (every
// transmitted signal must be received by at least one node).
fn test_unconsumed_producer_is_error() {
	mut s := clean_system()
	s.nodes[0].view.produces['can0'] = ['Speed', 'Spare']
	issues := validate_system(s)
	assert errs(issues).any(it.contains('Spare') && it.contains('no node receives it')), errs(issues).str()
}

// REQ-TOPO-002: two nodes sharing an NM id is an error.
fn test_shared_nm_id_is_error() {
	mut s := clean_system()
	s.nodes[1].nm = 0x11 // collide with sysnode
	issues := validate_system(s)
	e := errs(issues)
	assert e.any(it.contains('NM id 0x11') && it.contains('shared')), e.str()
	assert 'REQ-TOPO-002' in reqs_of(issues, .error)
}

// REQ-TOPO-002: shared diagnostic address is an error.
fn test_shared_diag_addr_is_error() {
	mut s := clean_system()
	s.nodes[0].diag = Diag{
		req: 0x7a0
		rsp: 0x7a8
	}
	s.nodes[1].diag = Diag{
		req: 0x7a0
		rsp: 0x7a8
	}
	issues := validate_system(s)
	assert errs(issues).any(it.contains('diagnostic request id 0x7a0')), errs(issues).str()
}

// REQ-TOPO-002: shared trace id is an error.
fn test_shared_trace_id_is_error() {
	mut s := clean_system()
	s.nodes[1].trace = 1 // collide with sysnode
	issues := validate_system(s)
	assert errs(issues).any(it.contains('trace node id 1')), errs(issues).str()
}

// REQ-TOPO-002: two nodes sharing an alive (on-wire NM) id is an error.
fn test_shared_alive_id_is_error() {
	mut s := clean_system()
	s.nodes[1].view.alive = 0x511 // collide with sysnode's alive
	issues := validate_system(s)
	assert errs(issues).any(it.contains('alive id 0x511') && it.contains('shared')), errs(issues).str()
}

// REQ-TOPO-005: a node's own [nm] node id must match the system.toml allocation.
fn test_node_nm_disagreement_is_error() {
	mut s := clean_system()
	s.nodes[0].view.nm_node = 0x22 // ecu.toml says 0x22, system says 0x11
	issues := validate_system(s)
	assert errs(issues).any(it.contains('disagrees with system.toml')), errs(issues).str()
	assert 'REQ-TOPO-005' in reqs_of(issues, .error)
}

// REQ-TOPO-004: an alive id outside the cluster range is an error (not the node id).
fn test_alive_outside_range_is_error() {
	mut s := clean_system()
	s.nodes[0].view.alive = 0x600 // outside [0x500,0x53f]
	issues := validate_system(s)
	assert errs(issues).any(it.contains('alive id 0x600')
		&& it.contains('outside its cluster range')), errs(issues).str()
}

// REQ-TOPO-004: nodes on one bus must agree on the cluster range.
fn test_nm_cluster_mismatch_is_error() {
	mut s := clean_system()
	s.nodes[1].view.peers_hi = 0x5ff // different range
	issues := validate_system(s)
	assert errs(issues).any(it.contains('cluster range mismatch')), errs(issues).str()
	assert 'REQ-TOPO-004' in reqs_of(issues, .error)
}

// REQ-TOPO-006: a route to an undeclared gateway / same bus / both frame+signal.
fn test_route_validity() {
	mut s := clean_system()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	// good route: sysnode is the gateway; but sysnode isn't on edge -> error
	s.routes << Route{
		gateway: 'sysnode'
		frame:   'VehStatus'
		from:    'compute'
		to:      'edge'
	}
	issues := validate_system(s)
	assert errs(issues).any(it.contains('does not sit on bus "edge"')), errs(issues).str()

	// same-bus route
	mut s2 := clean_system()
	s2.routes << Route{
		gateway: 'sysnode'
		frame:   'X'
		from:    'compute'
		to:      'compute'
	}
	assert errs(validate_system(s2)).any(it.contains('from and to are the same bus'))

	// both frame and signal set
	mut s3 := clean_system()
	s3.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s3.nodes[0].buses = ['compute', 'edge']
	s3.routes << Route{
		gateway: 'sysnode'
		frame:   'F'
		signal:  'S'
		from:    'compute'
		to:      'edge'
	}
	assert errs(validate_system(s3)).any(it.contains('exactly one of frame'))
}

// a signal produced on one bus and routed to another satisfies a consumer there.
fn test_route_satisfies_cross_bus_consumer() {
	mut s := clean_system()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[0].buses = ['compute', 'edge'] // sysnode gateways
	s.nodes[0].view.local_buses = ['can0', 'can1'] // the gateway opens both interfaces
	// zone consumes Speed on edge; only sysnode produces it on compute
	s.nodes << Node{
		name:         'zone'
		buses:        ['edge']
		nm:           0x20
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace:        3
		view:         NodeView{
			consumes:    {
				'can1': ['Speed']
			}
			has_nm:      true
			nm_enabled:  true
			nm_node:     0x20
			has_nm_node: true
			nm_node_ok:  true
			alive:       0x520
			has_alive:   true
			peers_lo:    0x500
			peers_hi:    0x53f
			local_buses: ['can1']
		}
	}
	// without a route -> error (no producer on edge)
	assert errs(validate_system(s)).any(it.contains('Speed') && it.contains('no node transmits'))
	// add the SIGNAL route -> it carries Speed compute->edge, so the cross-bus
	// consumer is satisfied AND (P2a) the signal route is accepted, not rejected.
	s.routes << Route{
		gateway: 'sysnode'
		signal:  'Speed'
		from:    'compute'
		to:      'edge'
	}
	e := errs(validate_system(s))
	assert !e.any(it.contains('Speed') && it.contains('no node transmits')), 'a signal route satisfies the cross-bus consumer: ${e}'
	assert !e.any(it.contains('not generated')), 'a signal route is generated in P2a, not rejected: ${e}'
}

// --- codex #141 review fixes ---

// REQ-TOPO-002: a shared diagnostic RESPONSE id collides even with distinct
// request ids (two ECUs answer on the same CAN id).
fn test_shared_diag_response_id_is_error() {
	mut s := clean_system()
	s.nodes[0].diag = Diag{
		req: 0x7a0
		rsp: 0x7a8
	}
	s.nodes[1].diag = Diag{
		req: 0x7b0
		rsp: 0x7a8 // distinct req, SAME rsp
	}
	issues := validate_system(s)
	assert errs(issues).any(it.contains('response id 0x7a8') && it.contains('collides')), errs(issues).str()
}

// REQ-TOPO-001/005: a bus a node claims must be declared AND map to a local
// interface in the node's ecu.toml — else the node's traffic is silently dropped.
fn test_bus_membership_errors() {
	mut s := clean_system()
	s.nodes[0].buses = ['nosuchbus'] // undeclared
	assert errs(validate_system(s)).any(it.contains('bus "nosuchbus" is not declared')), 'undeclared bus'

	mut s2 := clean_system()
	s2.nodes[0].view.local_buses = ['can9'] // ecu.toml doesn't open can0
	assert errs(validate_system(s2)).any(it.contains('no [bus.can0] interface')), 'missing local interface'
}

// REQ-TOPO-005: system.toml allocates an nm id but the node has no [nm] block.
fn test_missing_local_nm_is_error() {
	mut s := clean_system()
	s.nodes[0].view.has_nm = false // ecu.toml has no [nm]
	issues := validate_system(s)
	assert errs(issues).any(it.contains('has no [nm] block')), errs(issues).str()
	assert 'REQ-TOPO-005' in reqs_of(issues, .error)
}

// REQ-TOPO-004: nodes on one bus must agree on the sleep/wake timing.
fn test_nm_timing_mismatch_is_error() {
	mut s := clean_system()
	s.nodes[0].view.nm_timeout_ms = 300
	s.nodes[0].view.nm_has_timeout = true
	s.nodes[1].view.nm_timeout_ms = 500 // both declared, differ
	s.nodes[1].view.nm_has_timeout = true
	issues := validate_system(s)
	assert errs(issues).any(it.contains('timeout_ms mismatch')), errs(issues).str()
	// a param only one node declares must NOT false-positive (default vs explicit)
	mut s2 := clean_system()
	s2.nodes[0].view.nm_repeat_ms = 200 // only one declares it
	s2.nodes[0].view.nm_has_repeat = true
	assert !errs(validate_system(s2)).any(it.contains('repeat_ms mismatch')), 'one-sided default should not flag'
}

// REQ-TOPO-001: two nodes producing DIFFERENT signals that map to the SAME DBC
// message contend for one PDU on the wire — a frame collision each signal's
// single-writer check can't see. Ownership is derived from the produced signals
// resolved to their DBC message, not a [[frame]] tx-config block.
fn test_frame_single_writer_is_error() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_frameown_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// one message StatusFrame with two signals A (from a) and B (from b)
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a b

BO_ 288 StatusFrame: 8 a
 SG_ A : 0|8@1+ (1,0) [0|255] "" b
 SG_ B : 8|8@1+ (1,0) [0|255] "" a
') or {
		panic(err)
	}
	mut s := System{
		dir:   dir
		buses: [
			Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'compute.dbc'
			},
		]
		nodes: [
			Node{
				name:  'a'
				buses: ['compute']
				view:  NodeView{
					produces:    {
						'can0': ['A']
					}
					local_buses: ['can0']
				}
			},
			Node{
				name:  'b'
				buses: ['compute']
				view:  NodeView{
					produces:    {
						'can0': ['B']
					}
					local_buses: ['can0']
				}
			},
		]
	}
	assert errs(check_frame_single_writer(s)).any(it.contains('frame "StatusFrame"')
		&& it.contains('one frame owner')), errs(check_frame_single_writer(s)).str()
}

// REQ-TOPO-001: a signal route whose SOURCE bus has no producer does not satisfy
// a consumer — the gateway has nothing to forward.
fn test_route_without_source_producer_is_error() {
	mut s := clean_system()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[0].buses = ['compute', 'edge']
	s.nodes[0].view.local_buses = ['can0', 'can1']
	s.nodes << Node{
		name:         'zone'
		buses:        ['edge']
		nm:           0x20
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace:        3
		view:         NodeView{
			consumes:    {
				'can1': ['Torque']
			}
			has_nm:      true
			nm_enabled:  true
			nm_node:     0x20
			has_nm_node: true
			nm_node_ok:  true
			alive:       0x520
			has_alive:   true
			peers_lo:    0x500
			peers_hi:    0x53f
			local_buses: ['can1']
		}
	}
	// a route for Torque exists, but NOBODY produces Torque on compute
	s.routes << Route{
		gateway: 'sysnode'
		signal:  'Torque'
		from:    'compute'
		to:      'edge'
	}
	assert errs(validate_system(s)).any(it.contains('Torque') && it.contains('no node transmits')), 'route without a source producer must not satisfy the consumer'
}

// --- codex #141 round-2 fixes ---

// REQ-TOPO-006: two system buses sharing an interface alias one physical channel.
fn test_duplicate_bus_interface_is_error() {
	mut s := clean_system()
	s.buses << Bus{
		name:      'edge'
		interface: 'can0' // same as compute
	}
	assert errs(validate_system(s)).any(it.contains('share interface "can0"')), 'dup interface'
}

// REQ-TOPO-002: duplicate node names break route/identity lookup.
fn test_duplicate_node_name_is_error() {
	mut s := clean_system()
	s.nodes[1].name = 'sysnode' // collide
	assert errs(validate_system(s)).any(it.contains('duplicate node name "sysnode"')), 'dup node name'
}

// REQ-TOPO-005: a local interface matching a system bus that the node forgets to
// claim in `buses` would silently drop its traffic — flag it.
fn test_unclaimed_local_interface_is_error() {
	mut s := clean_system()
	s.nodes[0].buses = [] // opens [bus.can0] but claims no bus
	assert errs(validate_system(s)).any(it.contains('does not claim') && it.contains('unchecked')), 'unclaimed interface'
}

// REQ-TOPO-005: [nm] node = 0 is a valid id; a system nm of 0x11 must still flag
// the disagreement (0 is not "unset" once [nm] declares node).
fn test_local_nm_node_zero_disagrees() {
	mut s := clean_system()
	s.nodes[0].view.nm_node = 0 // declared as 0...
	s.nodes[0].view.has_nm_node = true
	// ...but system.toml allocates 0x11
	assert errs(validate_system(s)).any(it.contains('disagrees with system.toml')), 'node=0 vs 0x11'
}

// REQ-TOPO-004: with 3 nodes, a param the FIRST omits must still catch a later
// conflict (per-parameter anchor, not the cluster anchor).
fn test_nm_timing_anchor_is_per_param() {
	mut s := clean_system()
	// sysnode omits timeout (0); domain sets 300; add a third at 500
	s.nodes[1].view.nm_timeout_ms = 300
	s.nodes[1].view.nm_has_timeout = true
	s.nodes << Node{
		name:         'third'
		buses:        ['compute']
		nm:           0x15
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace:        4
		view:         NodeView{
			has_nm:         true
			nm_enabled:     true
			nm_node:        0x15
			has_nm_node:    true
			nm_node_ok:     true
			alive:          0x515
			has_alive:      true
			peers_lo:       0x500
			peers_hi:       0x53f
			local_buses:    ['can0']
			nm_has_timeout: true
			nm_timeout_ms:  500 // conflicts with domain's 300
		}
	}
	assert errs(validate_system(s)).any(it.contains('timeout_ms mismatch') && it.contains('500')), 'per-param anchor'
}

// REQ-TOPO-005: a node whose ecu.toml can't pass ecucheck can't be a clean
// system — its structural errors surface through syscheck.
fn test_node_config_error_surfaces() {
	mut s := clean_system()
	s.nodes[0].view.config_errors = ['partition "app" is missing `core`']
	issues := validate_system(s)
	assert errs(issues).any(it.contains('ecu.toml invalid') && it.contains('missing `core`')), 'node config error'
}

// --- codex #141 round-3 fixes (declaration presence + full node gate) ---

// REQ-TOPO-005: a node with a local [nm] the system never allocated is invisible
// to the uniqueness check — every NM identity must be system-allocated.
fn test_unallocated_local_nm_is_error() {
	mut s := clean_system()
	s.nodes[0].has_nm_alloc = false // ecu.toml has [nm] but system.toml omits nm
	issues := validate_system(s)
	assert errs(issues).any(it.contains('allocates it no `nm`')), errs(issues).str()
	assert 'REQ-TOPO-005' in reqs_of(issues, .error)
}

// REQ-TOPO-005: an allocated node whose [nm] omits `node` still can't be
// generated (loom2v requires node) — has_nm true but has_nm_node false.
fn test_nm_block_without_node_id_is_error() {
	mut s := clean_system()
	s.nodes[0].view.has_nm_node = false // [nm] present, `node` absent
	issues := validate_system(s)
	assert errs(issues).any(it.contains('has no `node` id')), errs(issues).str()
}

// REQ-TOPO-002: alive = 0 is a valid CAN id, so two nodes both declaring it
// collide (0 must not read as "unset").
fn test_alive_zero_declared_collides() {
	mut s := clean_system()
	s.nodes[0].view.alive = 0
	s.nodes[1].view.alive = 0 // both explicitly 0, both has_alive
	issues := validate_system(s)
	assert errs(issues).any(it.contains('alive id 0x0') && it.contains('shared')), errs(issues).str()
}

// REQ-TOPO-005 (integration): the FULL per-node gate runs — an unknown key that
// ecumodel.validate alone would miss is caught by shelling to ecucheck.
fn test_full_node_gate_catches_unknown_key() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_gate_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'bad.toml'), '
[bus.can0]
interface = "can0"
fd = false
core = 0
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "t"
totally_unknown_key = 42
') or {
		panic(err)
	}
	view := load_node(os.join_path(dir, 'bad.toml')) or { panic(err) }
	assert view.config_errors.len > 0, 'ecucheck should flag the unknown key'
	assert view.config_errors.any(it.contains('unknown key') || it.contains('totally_unknown_key')), view.config_errors.str()
}

// --- codex #141 round-4 fixes ---

// REQ-TOPO-004: a node that OMITS a timing (runs at loom2v's default) conflicts
// with a peer that explicitly sets a different value.
fn test_nm_timing_effective_default_conflict() {
	mut s := clean_system()
	// node 0 omits timeout_ms (0 -> effective 300); node 1 sets 500
	s.nodes[1].view.nm_timeout_ms = 500
	s.nodes[1].view.nm_has_timeout = true
	issues := validate_system(s)
	assert errs(issues).any(it.contains('timeout_ms mismatch') && it.contains('300')
		&& it.contains('500')), errs(issues).str()
}

// REQ-TOPO-004/005: an [nm] enabled = false node is a non-participant — no
// missing-allocation error and no bogus cluster mismatch.
fn test_nm_disabled_node_is_nonparticipant() {
	mut s := clean_system()
	s.nodes[1].view.nm_enabled = false
	s.nodes[1].has_nm_alloc = false // no system nm — fine, it doesn't participate
	s.nodes[1].view.peers_hi = 0x5ff // a different range must NOT flag (it's inactive)
	issues := validate_system(s)
	assert !errs(issues).any(it.contains('cluster range mismatch')), 'disabled node should not flag: ${errs(issues)}'
	assert !errs(issues).any(it.contains('allocates it no')), 'disabled node needs no allocation'
}

// REQ-TOPO-001: an empty / typo'd system (no buses or nodes) is not a clean gate.
fn test_empty_system_rejected() {
	issues := validate_system(System{})
	assert errs(issues).any(it.contains('no [bus.*] declared'))
	assert errs(issues).any(it.contains('no [[node]] declared'))
}

// REQ-TOPO-001: an unknown top-level section (e.g. a misspelled [[nodes]]).
fn test_unknown_top_level_section_rejected() {
	mut s := clean_system()
	s.unknown_keys = ['nodes']
	assert errs(validate_system(s)).any(it.contains('unknown top-level section "nodes"'))
}

// REQ-TOPO-002: a named alive binding (a DBC message name) is NOT range/collision
// checked as a numeric 0 — parse leaves has_alive false for the string form.
fn test_named_alive_binding_not_numeric() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_alive_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'n.toml'), '
[bus.can0]
interface = "can0"
fd = false
core = 0
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "t" # trailing comment terminates the nested [[partition.thread]] parse (vlang/v#27684)
[target]
kind    = "threadx"
tick_ms = 1
[nm]
node  = 0x11
alive = "AliveMsg"
peers = [0x500, 0x53F]
[[isotp]]
name  = "diag"
bus   = "can0"
rx_id = 0x101
tx_id = 0x102
') or {
		panic(err)
	}
	view := load_node(os.join_path(dir, 'n.toml')) or { panic(err) }
	assert view.has_nm
	assert !view.has_alive, 'a named alive binding is not a numeric id'
	assert view.alive == 0
}

// --- codex #141 round-5 fixes ---

// REQ-TOPO-004: alive OMITTED -> loom2v derives peers_lo + node; validate that.
fn test_derived_default_alive() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dalive_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'n.toml'), '
[bus.can0]
interface = "can0"
fd = false
core = 0
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "t" # trailing comment (vlang/v#27684)
[nm]
node  = 0x40
peers = [0x500, 0x53F]
') or {
		panic(err)
	}
	view := load_node(os.join_path(dir, 'n.toml')) or { panic(err) }
	assert view.has_alive, 'an omitted alive derives peers_lo + node'
	assert view.alive == 0x540, 'derived alive should be 0x500 + 0x40 = 0x540, got 0x${view.alive.hex()}'
}

// REQ-TOPO-002: a disabled [nm] node does not collide with an active one.
fn test_disabled_node_no_nm_collision() {
	mut s := clean_system()
	s.nodes[1].nm = 0x11 // same as sysnode...
	s.nodes[1].view.nm_enabled = false // ...but disabled -> non-participant, no collision
	assert !errs(validate_system(s)).any(it.contains('NM id 0x11') && it.contains('shared')), 'disabled node should not collide'
}

// REQ-TOPO-004: an EXPLICIT timeout_ms = 0 is preserved (not normalized to the
// default), so it conflicts with a peer running the default.
fn test_explicit_zero_timing_conflict() {
	mut s := clean_system()
	s.nodes[0].view.nm_timeout_ms = 0 // explicit 0
	s.nodes[0].view.nm_has_timeout = true
	// node 1 omits timeout -> loom2v default 300; 0 vs 300 conflict
	assert errs(validate_system(s)).any(it.contains('timeout_ms mismatch') && it.contains('300')), 'explicit 0 vs default 300 must conflict'
}

// REQ-TOPO-005: a node matched to a system bus by INTERFACE, not the [bus] key —
// [bus.can0] interface = "can1" is a different channel than compute (can0).
fn test_bus_matched_by_interface() {
	mut s := clean_system()
	s.nodes[0].view.local_buses = ['can1'] // its [bus].interface is can1, not can0
	assert errs(validate_system(s)).any(it.contains('has no [bus.can0] interface')), 'membership is by interface'
}

// REQ-TOPO-004: NM coherence scoped to the node's nm.bus — a gateway with
// nm.bus = compute is not compared against the edge cluster.
fn test_nm_bus_scoping() {
	mut s := clean_system()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	// sysnode gateways compute+edge but runs NM only on compute
	s.nodes[0].buses = ['compute', 'edge']
	s.nodes[0].view.local_buses = ['can0', 'can1']
	s.nodes[0].view.nm_bus = 'can0' // its NM is on compute only
	// an edge-only node with a DIFFERENT cluster range must not clash with the gateway
	s.nodes << Node{
		name:         'zone'
		buses:        ['edge']
		nm:           0x21
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace:        3
		view:         NodeView{
			has_nm:      true
			nm_enabled:  true
			nm_node:     0x21
			has_nm_node: true
			nm_node_ok:  true
			nm_bus:      'can1'
			alive:       0x521
			has_alive:   true
			peers_lo:    0x510
			peers_hi:    0x5ff // a different range than compute's [0x500,0x53f]
			local_buses: ['can1']
		}
	}
	// the gateway (nm.bus=compute) must NOT be compared against edge's range
	assert !errs(validate_system(s)).any(it.contains('cluster range mismatch')), 'nm.bus scopes coherence: ${errs(validate_system(s))}'
}

// --- codex #141 round-6 fixes ---

// REQ-TOPO-004: NM TIMING coherence is scoped to nm.bus too (not just range/alive).
fn test_nm_bus_scoping_timing() {
	mut s := clean_system()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[0].buses = ['compute', 'edge']
	s.nodes[0].view.local_buses = ['can0', 'can1']
	s.nodes[0].view.nm_bus = 'can0' // NM on compute only
	s.nodes << Node{
		name:         'zone'
		buses:        ['edge']
		nm:           0x21
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace:        3
		view:         NodeView{
			has_nm:         true
			nm_enabled:     true
			nm_node:        0x21
			has_nm_node:    true
			nm_node_ok:     true
			nm_bus:         'can1'
			alive:          0x521
			has_alive:      true
			peers_lo:       0x500
			peers_hi:       0x53f
			local_buses:    ['can1']
			nm_has_timeout: true
			nm_timeout_ms:  999 // a different timeout than the gateway's default
		}
	}
	assert !errs(validate_system(s)).any(it.contains('timeout_ms mismatch')), 'nm.bus scopes timing: ${errs(validate_system(s))}'
}

// REQ-TOPO-002/005: a non-threadx target disables NM (loom2v emits none), so the
// node is a non-participant — no allocation/collision errors.
fn test_non_threadx_disables_nm() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_tgt_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'n.toml'), '
[bus.can0]
interface = "can0"
fd = false
core = 0
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "t" # (vlang/v#27684)
[nm]
node  = 0x11
peers = [0x500, 0x53F]
[target]
kind = "baremetal"
') or {
		panic(err)
	}
	view := load_node(os.join_path(dir, 'n.toml')) or { panic(err) }
	assert view.has_nm, 'the [nm] table is present'
	assert !view.nm_enabled, 'a non-threadx target disables NM (loom2v emits none)'
}

// REQ-TOPO-002: a system nm id outside 0..255 (a negative would cast to a huge u32).
fn test_system_nm_out_of_range() {
	mut s := clean_system()
	s.nodes[0].nm_alloc_ok = false // system.toml nm was out of range (e.g. -1 or 0x100)
	assert errs(validate_system(s)).any(it.contains('outside the 0..255 node-id range'))
}

// REQ-TOPO-005: a local [nm] node outside 0..255 (loom2v rejects it).
fn test_local_nm_node_out_of_range() {
	mut s := clean_system()
	s.nodes[0].view.nm_node_ok = false // e.g. node = -1 or node = 300
	assert errs(validate_system(s)).any(it.contains('outside the 0..255 range loom2v requires'))
}

// --- codex #141 round-7 fixes ---

// REQ-TOPO-006: a route missing an endpoint (only `from`, no `to`).
fn test_route_missing_endpoint() {
	mut s := clean_system()
	s.routes << Route{
		gateway: 'sysnode'
		frame:   'Status'
		from:    'compute'
		// no `to`
	}
	assert errs(validate_system(s)).any(it.contains('needs both `from` and `to`'))
}

// REQ-TOPO-002: two active nodes naming the same alive DBC binding collide.
fn test_named_alive_binding_collision() {
	mut s := clean_system()
	s.nodes[0].view.has_alive = false
	s.nodes[0].view.alive_binding = 'AliveMsg'
	s.nodes[1].view.has_alive = false
	s.nodes[1].view.alive_binding = 'AliveMsg' // same message name
	assert errs(validate_system(s)).any(it.contains('alive binding "AliveMsg"')
		&& it.contains('resolves to one CAN id'))
}

// REQ-TOPO-004: an omitted [nm].peers defaults to loom2v's 0x500..0x53f (so the
// derived alive is in range) — a load round-trip confirms the default.
fn test_omitted_peers_defaults() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_peers_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'n.toml'), '
[bus.can0]
interface = "can0"
fd = false
core = 0
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "t" # (vlang/v#27684)
[nm]
node = 0x11
[target]
kind = "threadx"
[telemetry]
enabled = true
bus = "can0"
id = 0x7E0
detail_id = 0x7E1
period_ms = 500
') or {
		panic(err)
	}
	view := load_node(os.join_path(dir, 'n.toml')) or { panic(err) }
	assert view.peers_lo == 0x500 && view.peers_hi == 0x53f, 'omitted peers -> loom2v default'
	assert view.alive == 0x511, 'derived alive = 0x500 + 0x11'
}

// REQ-TOPO-004: a gateway with NO [nm].bus runs NM on its telemetry bus.
fn test_implicit_nm_bus_is_telemetry() {
	mut s := clean_system()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[0].buses = ['compute', 'edge']
	s.nodes[0].view.local_buses = ['can0', 'can1']
	s.nodes[0].view.nm_bus = 'can0' // resolved from telemetry bus (no explicit nm.bus)
	s.nodes << Node{
		name:         'zone'
		buses:        ['edge']
		nm:           0x21
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace:        3
		view:         NodeView{
			has_nm:      true
			nm_enabled:  true
			nm_node:     0x21
			has_nm_node: true
			nm_node_ok:  true
			nm_bus:      'can1'
			alive:       0x521
			has_alive:   true
			peers_lo:    0x510
			peers_hi:    0x5ff
			local_buses: ['can1']
		}
	}
	// the gateway's NM runs on compute (its telemetry bus), so edge's different
	// range must NOT clash with it
	assert !errs(validate_system(s)).any(it.contains('cluster range mismatch')), 'implicit nm.bus = telemetry bus'
}

// parse_system + load_node round-trip on a written system.toml + node ecu.toml.
fn test_parse_and_load_roundtrip() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_test_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'node_a.toml'), '
[bus.can0]
[[signal]]
name = "Speed"
from = "app"
to   = "can0"
[[signal]]
name = "Rpm"
from = "can0"
to   = "app"
[nm]
node  = 0x11
peers = [0x500, 0x53F]
') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'system.toml'), '
[bus.compute]
interface = "can0"
fd = true
bitrate = 500000
dbc = "compute.dbc"
[[node]]
name = "a"
ecu = "node_a.toml"
buses = ["compute"]
nm = 0x11
diag = { req = 0x7A0, rsp = 0x7A8 }
trace = 1
') or {
		panic(err)
	}
	mut sys := parse_system(os.join_path(dir, 'system.toml')) or { panic(err) }
	assert sys.buses.len == 1
	assert sys.buses[0].interface == 'can0'
	assert sys.buses[0].fd
	assert sys.buses[0].bitrate == 500000
	assert sys.nodes.len == 1
	assert sys.nodes[0].nm == 0x11
	assert sys.nodes[0].diag.req == 0x7a0
	assert sys.nodes[0].diag.rsp == 0x7a8
	load_errs := sys.load_nodes()
	assert load_errs.len == 0, load_errs.str()
	assert sys.nodes[0].view.produces['can0'] == ['Speed']
	assert sys.nodes[0].view.consumes['can0'] == ['Rpm']
	assert sys.nodes[0].view.has_nm
	assert sys.nodes[0].view.peers_lo == 0x500
	assert sys.nodes[0].view.peers_hi == 0x53f
}

// --- codex #141 round-8 fixes ---

// REQ-TOPO-002: a NAMED [nm].alive binding resolves through the bus DBC to a
// numeric on-wire id during load, so it flows through the SAME uniqueness check
// as a literal — a name and a literal that hit the same id must not slip past in
// separate maps. Here "AliveMsg" is 0x511 in the DBC; after load_nodes the view
// carries alive = 0x511 (not a raw string), and the binding is cleared.
fn test_named_alive_resolves_via_dbc() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_ralive_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a

BO_ 1297 AliveMsg: 8 a
 SG_ Alive : 0|8@1+ (1,0) [0|255] "" a
') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'node_a.toml'), '
[bus.can0]
[telemetry]
bus = "can0"
[target]
kind    = "threadx"
tick_ms = 1
[nm]
node  = 0x11
alive = "AliveMsg"
peers = [0x500, 0x53F]
[[isotp]]
name  = "diag"
bus   = "can0"
rx_id = 0x101
tx_id = 0x102
') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'system.toml'), '
[bus.compute]
interface = "can0"
dbc = "compute.dbc"
[[node]]
name = "a"
ecu = "node_a.toml"
buses = ["compute"]
nm = 0x11
trace = 1
') or {
		panic(err)
	}
	mut sys := parse_system(os.join_path(dir, 'system.toml')) or { panic(err) }
	load_errs := sys.load_nodes()
	assert load_errs.len == 0, load_errs.str()
	assert sys.nodes[0].view.has_alive, 'named alive should resolve to a numeric id'
	assert sys.nodes[0].view.alive == 0x511, 'AliveMsg is 0x511 in the DBC, got 0x${sys.nodes[0].view.alive.hex()}'
	assert sys.nodes[0].view.alive_binding == '', 'a resolved binding is cleared'
}

// A named [nm].alive whose message is absent from the bus DBC is a load error
// (loom2v would fail to resolve it too).
fn test_named_alive_unknown_message_errors() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_ualive_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a

BO_ 1297 OtherMsg: 8 a
 SG_ X : 0|8@1+ (1,0) [0|255] "" a
') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'node_a.toml'), '
[bus.can0]
[telemetry]
bus = "can0"
[target]
kind    = "threadx"
tick_ms = 1
[nm]
node  = 0x11
alive = "AliveMsg"
peers = [0x500, 0x53F]
[[isotp]]
name  = "diag"
bus   = "can0"
rx_id = 0x101
tx_id = 0x102
') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'system.toml'), '
[bus.compute]
interface = "can0"
dbc = "compute.dbc"
[[node]]
name = "a"
ecu = "node_a.toml"
buses = ["compute"]
nm = 0x11
trace = 1
') or {
		panic(err)
	}
	mut sys := parse_system(os.join_path(dir, 'system.toml')) or { panic(err) }
	load_errs := sys.load_nodes()
	assert load_errs.any(it.contains('no such message')), load_errs.str()
}

// --- codex #141 round-9 fixes ---

// REQ-TOPO-004: loom2v runs NM on the TELEMETRY bus (nm.bus only labels the
// manifest), so an explicit [nm].bus other than [telemetry].bus is rejected —
// otherwise coherence is scoped to a bus the node doesn't physically run NM on.
fn test_nm_bus_must_match_telemetry() {
	mut s := clean_system()
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.comm_thread_on = true
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.nm_bus = 'can1' // differs from the telemetry bus
	assert errs(validate_system(s)).any(it.contains('[nm].bus "can1"')
		&& it.contains('[telemetry].bus "can0"')), errs(validate_system(s)).str()
}

// REQ-TOPO-001: a local interface no system bus declares, carrying bus-facing
// signals, has no system contract — its traffic must not silently pass unchecked.
fn test_undeclared_interface_with_signals_is_error() {
	mut s := clean_system()
	s.nodes[0].view.local_buses = ['can0', 'can1'] // can1 is not a system bus
	s.nodes[0].view.produces['can1'] = ['Extra'] // ...yet it transmits there
	assert errs(validate_system(s)).any(it.contains('[bus.can1]')
		&& it.contains('no system contract')), errs(validate_system(s)).str()
}

// The per-node gate runs ecucheck via run_capture, which uses an ARGUMENT VECTOR
// rather than a shell string — so an untrusted path (an `ecu = "$(...)"` a
// system.toml names) is passed literally and cannot run code (regression).
fn test_run_capture_does_not_shell() {
	if !os.exists('/bin/echo') {
		return
	}
	dir := os.join_path(os.temp_dir(), 'sysmodel_argv_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	marker := os.join_path(dir, 'pwned')
	// were this exec'd through a shell, `$(touch <marker>)` would create the
	// marker; through an argv it is just a literal string echo prints back.
	out, _ := run_capture('/bin/echo', ['\$(touch ${marker})'])
	assert !os.exists(marker), 'run_capture executed a shell command substitution'
	assert out.contains('touch'), 'echo should print the arg literally: ${out}'
}

// --- codex #141 round-10 fixes ---

// REQ-TOPO-002: two threadx nodes with the same [telemetry].id on one bus both
// transmit that CAN id — a telemetry-frame multi-writer the [[frame]] single-
// writer check can't see (telemetry ids live in [telemetry], not [[frame]]).
fn test_telemetry_id_collision_is_error() {
	mut s := clean_system()
	for i in 0 .. 2 {
		s.nodes[i].view.is_threadx = true
		s.nodes[i].view.comm_thread_on = true
		s.nodes[i].view.has_telemetry = true
		s.nodes[i].view.telem_bus = 'can0'
		s.nodes[i].view.nm_bus = 'can0'
	}
	s.nodes[0].view.telem_id = 0x7e0
	s.nodes[1].view.telem_id = 0x7e0 // same telemetry id on the same bus
	assert errs(validate_system(s)).any(it.contains('telemetry id 0x7e0')
		&& it.contains('single-writer')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: an OMITTED telemetry id defaults to 0 and CpuLoad is always sent,
// so two id-less threadx nodes both transmit at CAN id 0.
fn test_omitted_telemetry_ids_collide_at_zero() {
	mut s := clean_system()
	for i in 0 .. 2 {
		s.nodes[i].view.is_threadx = true
		s.nodes[i].view.comm_thread_on = true
		s.nodes[i].view.has_telemetry = true
		s.nodes[i].view.telem_bus = 'can0'
		s.nodes[i].view.nm_bus = 'can0'
		s.nodes[i].view.telem_id = 0 // both omit -> effective 0
	}
	assert errs(validate_system(s)).any(it.contains('telemetry id 0x0')
		&& it.contains('single-writer')), errs(validate_system(s)).str()
}

// REQ-TOPO-004: a named [nm].alive binding whose bus has no DBC cannot be
// resolved to a CAN id — a load error, not a silent clean fall-through.
fn test_named_alive_without_dbc_is_error() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_nodbc_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'n.toml'), '
[bus.can0]
interface = "can0"
fd = false
core = 0
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "t" # trailing comment (vlang/v#27684)
[telemetry]
bus = "can0"
[target]
kind    = "threadx"
tick_ms = 1
[nm]
node  = 0x11
alive = "AliveMsg"
peers = [0x500, 0x53F]
[[isotp]]
name  = "diag"
bus   = "can0"
rx_id = 0x101
tx_id = 0x102
') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'system.toml'), '
[bus.compute]
interface = "can0"
[[node]]
name = "a"
ecu = "n.toml"
buses = ["compute"]
nm = 0x11
trace = 1
') or {
		panic(err)
	}
	mut sys := parse_system(os.join_path(dir, 'system.toml')) or { panic(err) }
	load_errs := sys.load_nodes()
	assert load_errs.any(it.contains('no `dbc` to resolve')), load_errs.str()
}

// --- codex #141 round-11 fixes ---

// REQ-TOPO-005: loom2v's parse_telemetry defaults an omitted `enabled` to false,
// so [telemetry] with a bus but no enabled key does NOT give a threadx node its
// telemetry channel — it fails the same way a missing [telemetry] does.
fn test_telemetry_enabled_defaults_false() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_tenon_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'n.toml'), '
[bus.can0]
interface = "can0"
fd = false
core = 0
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "t" # trailing comment (vlang/v#27684)
[target]
kind    = "threadx"
tick_ms = 1
[telemetry]
bus = "can0"
') or {
		panic(err)
	}
	view := load_node(os.join_path(dir, 'n.toml')) or { panic(err) }
	assert !view.has_telemetry, 'omitted [telemetry].enabled must default to false (loom2v parse_telemetry)'
}

// REQ-TOPO-001: a threadx node whose telemetry interface is a local bus no system
// bus declares transmits telemetry on an undeclared channel — flagged even with
// no application signal on it.
fn test_undeclared_telemetry_interface_is_error() {
	mut s := clean_system()
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.comm_thread_on = true
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can9' // not a system bus interface
	s.nodes[0].view.nm_bus = 'can9'
	s.nodes[0].view.local_buses = ['can0', 'can9']
	assert errs(validate_system(s)).any(it.contains('[bus.can9]') && it.contains('telemetry')), errs(validate_system(s)).str()
}

// --- codex #141 round-12 fixes ---

// REQ-TOPO-006: a FRAME (raw-PDU) route is not generated until P2b (its
// full-contract compare + tx-ready forwarder), so its mere presence is still an
// error — a clean verdict must not imply a forwarder exists. (Signal routes ARE
// generated in P2a — see test_signal_route_accepted.)
fn test_frame_route_not_generated_is_error() {
	mut s := clean_system()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[0].buses = ['compute', 'edge']
	s.nodes[0].view.local_buses = ['can0', 'can1']
	s.routes << Route{
		gateway: 'sysnode'
		frame:   'VehFrame'
		from:    'compute'
		to:      'edge'
	}
	assert errs(validate_system(s)).any(it.contains('not generated yet (P2b)')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: a telemetry id equal to ANOTHER node's alive id collides on the
// wire — checked against every active NM participant, not just the sender's range.
fn test_telemetry_id_aliases_other_node_alive() {
	mut s := clean_system()
	// node 0 has NO NM of its own but transmits telemetry at 0x513 = node 1's alive
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.comm_thread_on = true
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.nm_bus = 'can0'
	s.nodes[0].view.has_nm = false
	s.nodes[0].view.nm_enabled = false
	s.nodes[0].view.telem_id = 0x513 // == node 1's alive id
	// node 1 is an active NM participant with alive 0x513 (from clean_system)
	s.nodes[1].view.nm_bus = 'can0'
	assert errs(validate_system(s)).any(it.contains('telemetry id 0x513')
		&& it.contains('NM alive id of "domain"')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: a threadx node's exec-hook trace record frame (default 0x7e5)
// must not collide with another trace/telemetry frame on the same bus.
fn test_trace_record_id_collision_is_error() {
	mut s := clean_system()
	for i in 0 .. 2 {
		s.nodes[i].view.is_threadx = true
		s.nodes[i].view.comm_thread_on = true
		s.nodes[i].view.has_telemetry = true
		s.nodes[i].view.telem_bus = 'can0'
		s.nodes[i].view.nm_bus = 'can0'
		s.nodes[i].view.telem_id = u32(0x7a0 + i) // distinct telemetry ids
		s.nodes[i].view.trace_on = true
		s.nodes[i].view.trace_record_id = 0x7e5 // both default -> collide
	}
	assert errs(validate_system(s)).any(it.contains('trace record id 0x7e5')
		&& it.contains('single-writer')), errs(validate_system(s)).str()
}

// REQ-TOPO-004: a DISABLED [nm] block with a named alive binding needs no DBC —
// loom2v resolves no binding for an inactive NM, so it must not be a load error.
fn test_named_alive_inactive_nm_no_dbc_ok() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_inactnm_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// no [target] threadx -> nm_enabled = false, so the named alive is inert
	os.write_file(os.join_path(dir, 'n.toml'), '
[bus.can0]
interface = "can0"
fd = false
core = 0
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "t" # trailing comment (vlang/v#27684)
[nm]
node  = 0x11
alive = "AliveMsg"
peers = [0x500, 0x53F]
[[isotp]]
name  = "diag"
bus   = "can0"
rx_id = 0x101
tx_id = 0x102
') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'system.toml'), '
[bus.compute]
interface = "can0"
[[node]]
name = "a"
ecu = "n.toml"
buses = ["compute"]
nm = 0x11
trace = 1
') or {
		panic(err)
	}
	mut sys := parse_system(os.join_path(dir, 'system.toml')) or { panic(err) }
	load_errs := sys.load_nodes()
	assert !load_errs.any(it.contains('alive')), 'inactive NM named alive must not require a DBC: ${load_errs}'
}

// --- codex #141 round-13 fixes ---

// REQ-TOPO-002: two nodes physically using the same ISO-TP diagnostic id collide
// on the wire even when their system.toml diag allocations differ.
fn test_isotp_id_collision_is_error() {
	mut s := clean_system()
	s.nodes[0].view.isotp_conns = [IsotpConn{
		iface: 'can0'
		rx_id: 0x700
	}]
	s.nodes[1].view.isotp_conns = [IsotpConn{
		iface: 'can0'
		rx_id: 0x700
	}] // same on-wire diag id
	assert errs(validate_system(s)).any(it.contains('[[isotp]] diagnostic id 0x700')
		&& it.contains('collides')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: a host (non-threadx) node with telemetry still transmits CpuLoad,
// so two host telemetry nodes sharing an id collide.
fn test_host_telemetry_id_collision() {
	mut s := clean_system()
	for i in 0 .. 2 {
		s.nodes[i].view.is_threadx = false // host target
		s.nodes[i].view.has_telemetry = true
		s.nodes[i].view.telem_bus = 'can0'
		s.nodes[i].view.telem_id = 0x7e0 // same id
	}
	assert errs(validate_system(s)).any(it.contains('telemetry id 0x7e0')
		&& it.contains('single-writer')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: a threadx node's shell.out response frame (default 0x7f1) is a
// real tx frame that must not collide with another node's telemetry/shell frame.
fn test_shell_out_id_collision_is_error() {
	mut s := clean_system()
	for i in 0 .. 2 {
		s.nodes[i].view.is_threadx = true
		s.nodes[i].view.comm_thread_on = true
		s.nodes[i].view.has_telemetry = true
		s.nodes[i].view.telem_bus = 'can0'
		s.nodes[i].view.nm_bus = 'can0'
		s.nodes[i].view.telem_id = u32(0x7a0 + i) // distinct telemetry ids
		s.nodes[i].view.shell_on = true
		s.nodes[i].view.shell_out_id = 0x7f1 // both default -> collide
	}
	assert errs(validate_system(s)).any(it.contains('shell out id 0x7f1')
		&& it.contains('single-writer')), errs(validate_system(s)).str()
}

// --- codex #141 round-14 fixes ---

// REQ-TOPO-002: the TraceModule transmits command RESPONSES (rsp_id, default
// 0x7e3) too, not just records — two nodes sharing a trace rsp id collide.
fn test_trace_rsp_id_collision() {
	mut s := clean_system()
	for i in 0 .. 2 {
		s.nodes[i].view.is_threadx = true
		s.nodes[i].view.comm_thread_on = true
		s.nodes[i].view.has_telemetry = true
		s.nodes[i].view.telem_bus = 'can0'
		s.nodes[i].view.nm_bus = 'can0'
		s.nodes[i].view.telem_id = u32(0x7a0 + i) // distinct telemetry
		s.nodes[i].view.trace_on = true
		s.nodes[i].view.trace_record_id = u32(0x7b0 + i) // distinct records
		s.nodes[i].view.trace_rsp_id = 0x7e3 // same rsp -> collide
	}
	assert errs(validate_system(s)).any(it.contains('trace rsp id 0x7e3')
		&& it.contains('single-writer')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: a host node can trace on [trace].bus with telemetry DISABLED, so
// two such nodes with colliding record ids must still be caught.
fn test_host_trace_without_telemetry_collision() {
	mut s := clean_system()
	for i in 0 .. 2 {
		s.nodes[i].view.is_threadx = false // host target
		s.nodes[i].view.has_telemetry = false // telemetry off
		s.nodes[i].view.trace_on = true
		s.nodes[i].view.trace_bus = 'can0' // trace rides the compute bus
		s.nodes[i].view.trace_record_id = 0x7e5 // same record id -> collide
		// host trace generates only for the single-partition, no-COM-bridge shape
		s.nodes[i].view.partition_count = 1
		s.nodes[i].view.produces = map[string][]string{}
		s.nodes[i].view.consumes = map[string][]string{}
	}
	assert errs(validate_system(s)).any(it.contains('trace record id 0x7e5')
		&& it.contains('single-writer')), errs(validate_system(s)).str()
}

// --- codex #141 round-15 fixes ---

// REQ-TOPO-002: a module endpoint BOUND to a DBC message name is that frame by
// design (loom2v supports it) — it must NOT be flagged as aliasing an application
// frame. Here trace.record binds to the DBC message; expect no alias error.
fn test_bound_endpoint_not_dbc_alias() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_bound_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a

BO_ 288 TraceRecord: 8 a
 SG_ X : 0|8@1+ (1,0) [0|255] "" a
') or {
		panic(err)
	}
	mut s := System{
		dir:   dir
		buses: [
			Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'compute.dbc'
			},
		]
		nodes: [
			Node{
				name:  'a'
				buses: ['compute']
				view:  NodeView{
					is_threadx:        true
					comm_thread_on:    true
					has_telemetry:     true
					telem_bus:         'can0'
					trace_on:          true
					trace_record_name: 'trace_record' // snake of "TraceRecord" -> 0x120
					trace_rsp_id:      0x7e3
				}
			},
		]
	}
	// the bound record resolves to 0x120 (=TraceRecord) but must NOT be an alias error
	assert !errs(check_telemetry_frames(s)).any(it.contains('aliases DBC application frame')), errs(check_telemetry_frames(s)).str()
}

// REQ-TOPO-002: a node's module RECEIVE id (trace cmd, default 0x7e2) is reserved
// — another node transmitting telemetry there would be misrouted into on_cmd.
fn test_module_rx_id_reserved() {
	mut s := clean_system()
	// node 0 traces: distinct tx ids + the default rx ids (0x7e2 cmd, 0x7e6 dump_fc)
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.comm_thread_on = true
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.nm_bus = 'can0'
	s.nodes[0].view.telem_id = 0x7a0
	s.nodes[0].view.trace_on = true
	s.nodes[0].view.trace_record_id = 0x7a1
	s.nodes[0].view.trace_rsp_id = 0x7a2
	s.nodes[0].view.trace_cmd_id = 0x7e2 // reserved rx
	s.nodes[0].view.trace_dump_fc_id = 0x7e6 // reserved rx
	s.nodes[1].view.is_threadx = true
	s.nodes[1].view.comm_thread_on = true
	s.nodes[1].view.has_telemetry = true
	s.nodes[1].view.telem_bus = 'can0'
	s.nodes[1].view.nm_bus = 'can0'
	s.nodes[1].view.telem_id = 0x7e2 // transmits at node 0's reserved trace cmd id
	assert errs(validate_system(s)).any(it.contains('telemetry id 0x7e2')
		&& it.contains('trace cmd (rx) id of "sysnode"')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: a named binding resolves the way loom2v does (snake-normalized),
// so record = "trace_record" hits DBC "TraceRecord" — two nodes both binding it
// (to the same id) collide.
fn test_named_binding_snake_normalized() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_snake_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a b

BO_ 300 TraceRecord: 8 a
 SG_ X : 0|8@1+ (1,0) [0|255] "" b
') or {
		panic(err)
	}
	mut s := System{
		dir:   dir
		buses: [
			Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'compute.dbc'
			},
		]
		nodes: [
			Node{
				name:  'a'
				buses: ['compute']
				view:  NodeView{
					is_threadx:        true
					comm_thread_on:    true
					has_telemetry:     true
					telem_bus:         'can0'
					telem_id:          0x7a0
					trace_on:          true
					trace_record_name: 'trace_record' // -> 0x12c
					trace_rsp_id:      0x7a1
				}
			},
			Node{
				name:  'b'
				buses: ['compute']
				view:  NodeView{
					is_threadx:        true
					comm_thread_on:    true
					has_telemetry:     true
					telem_bus:         'can0'
					telem_id:          0x7a2
					trace_on:          true
					trace_record_name: 'TraceRecord' // same PDU, different spelling -> 0x12c
					trace_rsp_id:      0x7a3
				}
			},
		]
	}
	assert errs(check_telemetry_frames(s)).any(it.contains('trace record id 0x12c')
		&& it.contains('single-writer')), errs(check_telemetry_frames(s)).str()
}

// REQ-TOPO-004: an active NM alive id above 0x7ff is masked to 11 bits by the
// FDCAN backend, so it must be rejected (0x811 goes out as 0x11).
fn test_active_nm_alive_over_11bit_is_error() {
	mut s := clean_system()
	s.nodes[0].view.peers_lo = 0x800
	s.nodes[0].view.peers_hi = 0x83f
	s.nodes[0].view.alive = 0x811
	s.nodes[1].view.peers_lo = 0x800
	s.nodes[1].view.peers_hi = 0x83f
	s.nodes[1].view.alive = 0x813
	assert errs(validate_system(s)).any(it.contains('exceeds 0x7ff') && it.contains('11-bit')), errs(validate_system(s)).str()
}

// --- codex #141 round-16 fixes ---

// REQ-TOPO-005: a node's local [bus.X].fd must match the system bus contract.
fn test_fd_mode_mismatch_is_error() {
	mut s := clean_system()
	s.buses[0].fd = false // system bus is classic
	s.nodes[0].view.local_bus_fd = {
		'can0': true
	} // but the node opens it as FD
	assert errs(validate_system(s)).any(it.contains('fd = true')
		&& it.contains('one CAN mode per wire')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: shell.fc (default 0x7f2) is a reserved RX id — another node
// transmitting there is misrouted into g_sh.on_fc.
fn test_shell_fc_id_reserved() {
	mut s := clean_system()
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.comm_thread_on = true
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.nm_bus = 'can0'
	s.nodes[0].view.telem_id = 0x7a0
	s.nodes[0].view.shell_on = true
	s.nodes[0].view.shell_out_id = 0x7f1
	s.nodes[0].view.shell_in_id = 0x7f0
	s.nodes[0].view.shell_fc_id = 0x7f2 // reserved rx
	s.nodes[1].view.is_threadx = true
	s.nodes[1].view.comm_thread_on = true
	s.nodes[1].view.has_telemetry = true
	s.nodes[1].view.telem_bus = 'can0'
	s.nodes[1].view.nm_bus = 'can0'
	s.nodes[1].view.telem_id = 0x7f2 // transmits at node 0's reserved shell fc id
	assert errs(validate_system(s)).any(it.contains('telemetry id 0x7f2')
		&& it.contains('shell fc (rx) id of "sysnode"')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: a named module binding that resolves to no DBC message fails
// loom2v generation, so syscheck must reject it (not silently use the default id).
fn test_unresolved_named_binding_is_error() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_unres_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a

BO_ 288 Other: 8 a
 SG_ X : 0|32@1+ (1,0) [0|4294967295] "" a
') or {
		panic(err)
	}
	mut s := System{
		dir:   dir
		buses: [
			Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'compute.dbc'
			},
		]
		nodes: [
			Node{
				name:  'a'
				buses: ['compute']
				view:  NodeView{
					is_threadx:        true
					comm_thread_on:    true
					has_telemetry:     true
					telem_bus:         'can0'
					telem_id:          0x7a0
					trace_on:          true
					trace_record_name: 'NoSuchMessage' // not in the DBC
					trace_rsp_id:      0x7a1
				}
			},
		]
	}
	assert errs(validate_system(s)).any(it.contains('NoSuchMessage')
		&& it.contains('does not exist')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: a MULTI-partition host node builds WITHOUT trace, so its trace
// ids are not on the wire and must not be reserved/collision-checked.
fn test_multipartition_host_trace_not_reserved() {
	mut s := clean_system()
	// two host nodes, each multi-partition, both "trace" at 0x7e5 — but neither
	// actually generates trace, so there must be NO collision reported.
	for i in 0 .. 2 {
		s.nodes[i].view.is_threadx = false
		s.nodes[i].view.has_telemetry = false
		s.nodes[i].view.trace_on = true
		s.nodes[i].view.trace_bus = 'can0'
		s.nodes[i].view.trace_record_id = 0x7e5
		s.nodes[i].view.partition_count = 3 // multi-partition -> no host trace
		s.nodes[i].view.produces = map[string][]string{}
		s.nodes[i].view.consumes = map[string][]string{}
	}
	assert !errs(validate_system(s)).any(it.contains('trace record id 0x7e5')), errs(validate_system(s)).str()
}

// --- codex #141 round-17: run the real loom2v per node ---

// REQ-TOPO-005: a node that passes ecucheck (valid schema) but that loom2v cannot
// generate (here a threadx [trace].level the exec-hook recorder can't produce) is
// caught by the loom2v gate, so a clean syscheck implies a generatable node. This
// one covers the whole family of round-17 target constraints at once.
fn test_node_generatable_gate_catches_loom2v_panic() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_gen_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a

BO_ 288 VehSpeedFrame: 8 a
 SG_ VehicleSpeed : 0|32@1+ (1,0) [0|4294967295] "" a
') or {
		panic(err)
	}
	// a schema-valid threadx node whose [trace].level = "fb" loom2v rejects
	os.write_file(os.join_path(dir, 'n.toml'), '
[bus.can0]
interface = "can0"
fd = false
core = 0
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "t" # trailing comment (vlang/v#27684)
[target]
kind    = "threadx"
tick_ms = 1
[telemetry]
enabled   = true
bus       = "can0"
id        = 0x7E0
[trace]
enabled = true
bus     = "can0"
level   = "fb"
') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'system.toml'), '
[bus.compute]
interface = "can0"
dbc = "compute.dbc"
[[node]]
name = "a"
ecu = "n.toml"
buses = ["compute"]
nm = 0x11
trace = 1
') or {
		panic(err)
	}
	mut sys := parse_system(os.join_path(dir, 'system.toml')) or { panic(err) }
	sys.load_nodes()
	assert errs(validate_system(sys)).any(it.contains('not generatable')), errs(validate_system(sys)).str()
}

// --- codex #141 round-18 fixes ---

// REQ-TOPO-002: dump_fc reserves an rx id ONLY when explicitly bound — an unbound
// node (the normal case) has no dump_fc receiver, so a peer at 0x7e6 is fine.
fn test_unbound_dump_fc_not_reserved() {
	mut s := clean_system()
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.comm_thread_on = true
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.nm_bus = 'can0'
	s.nodes[0].view.telem_id = 0x7a0
	s.nodes[0].view.trace_on = true
	s.nodes[0].view.trace_record_id = 0x7a1
	s.nodes[0].view.trace_rsp_id = 0x7a2
	s.nodes[0].view.trace_cmd_id = 0x7e2
	s.nodes[0].view.trace_dump_fc_id = 0x7e6
	s.nodes[0].view.trace_dump_fc_bound = false // NOT bound -> no receiver
	s.nodes[1].view.is_threadx = true
	s.nodes[1].view.comm_thread_on = true
	s.nodes[1].view.has_telemetry = true
	s.nodes[1].view.telem_bus = 'can0'
	s.nodes[1].view.nm_bus = 'can0'
	s.nodes[1].view.telem_id = 0x7e6 // == node 0's unbound dump_fc id -> should be OK
	assert !errs(validate_system(s)).any(it.contains('0x7e6')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: bound dump_fc IS reserved.
fn test_bound_dump_fc_reserved() {
	mut s := clean_system()
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.comm_thread_on = true
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.nm_bus = 'can0'
	s.nodes[0].view.telem_id = 0x7a0
	s.nodes[0].view.trace_on = true
	s.nodes[0].view.trace_record_id = 0x7a1
	s.nodes[0].view.trace_rsp_id = 0x7a2
	s.nodes[0].view.trace_cmd_id = 0x7e2
	s.nodes[0].view.trace_dump_fc_id = 0x7e6
	s.nodes[0].view.trace_dump_fc_bound = true // bound -> reserved
	s.nodes[1].view.is_threadx = true
	s.nodes[1].view.comm_thread_on = true
	s.nodes[1].view.has_telemetry = true
	s.nodes[1].view.telem_bus = 'can0'
	s.nodes[1].view.nm_bus = 'can0'
	s.nodes[1].view.telem_id = 0x7e6 // collides with node 0's bound dump_fc rx id
	assert errs(validate_system(s)).any(it.contains('telemetry id 0x7e6') && it.contains('dump_fc')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: a single-partition HOST trace runner sends inline CpuLoad only,
// never LoadDetail — a peer using that detail id is not a collision.
fn test_host_trace_detail_not_counted() {
	mut s := clean_system()
	s.nodes[0].view.is_threadx = false // host trace runner
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.telem_id = 0x7a0
	s.nodes[0].view.telem_detail_id = 0x7a1 // NOT sent by the host trace runner
	s.nodes[0].view.trace_on = true
	s.nodes[0].view.trace_bus = 'can0'
	s.nodes[0].view.trace_record_id = 0x7a2
	s.nodes[0].view.trace_rsp_id = 0x7a3
	s.nodes[0].view.partition_count = 1
	s.nodes[0].view.produces = map[string][]string{}
	s.nodes[0].view.consumes = map[string][]string{}
	s.nodes[1].view.telem_id = 0x7a1 // == node 0's (unsent) detail id -> OK
	s.nodes[1].view.is_threadx = false
	s.nodes[1].view.has_telemetry = true
	s.nodes[1].view.telem_bus = 'can0'
	assert !errs(validate_system(s)).any(it.contains('0x7a1')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: a DBC application frame in an active NM peer range is misread as
// an alive frame by the NM receiver.
fn test_app_frame_in_nm_range_is_error() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_appnm_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// SpeedFrame id 0x511 sits inside the cluster range [0x500,0x53f]
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a

BO_ 1312 SpeedFrame: 8 a
 SG_ Speed : 0|32@1+ (1,0) [0|4294967295] "" a
') or {
		panic(err)
	}
	mut s := System{
		dir:   dir
		buses: [
			Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'compute.dbc'
			},
		]
		nodes: [
			Node{
				name:  'a'
				buses: ['compute']
				view:  NodeView{
					has_nm:      true
					nm_enabled:  true
					nm_bus:      'can0'
					peers_lo:    0x500
					peers_hi:    0x53f
					alive:       0x511
					has_alive:   true
					local_buses: ['can0']
				}
			},
		]
	}
	assert errs(check_telemetry_frames(s)).any(it.contains('SpeedFrame')
		&& it.contains('NM peer range')), errs(check_telemetry_frames(s)).str()
}

// --- codex #141 round-20 fixes ---

// REQ-TOPO-002: a DBC message BOUND as [nm].alive IS the alive frame, so it must
// NOT be flagged as an application frame in the NM peer range.
fn test_alive_bound_frame_not_flagged_as_app() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_alivebind_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// AliveMsg at 0x511 (inside the cluster range) is the alive frame, not an app frame
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a

BO_ 1297 AliveMsg: 8 a
 SG_ X : 0|8@1+ (1,0) [0|255] "" a
') or {
		panic(err)
	}
	mut s := System{
		dir:   dir
		buses: [
			Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'compute.dbc'
			},
		]
		nodes: [
			Node{
				name:  'a'
				buses: ['compute']
				view:  NodeView{
					has_nm:             true
					nm_enabled:         true
					nm_bus:             'can0'
					peers_lo:           0x500
					peers_hi:           0x53f
					alive:              0x511 // resolved from the AliveMsg binding
					has_alive:          true
					alive_from_binding: true // AliveMsg is explicitly the alive frame
					local_buses:        ['can0']
				}
			},
		]
	}
	assert !errs(check_telemetry_frames(s)).any(it.contains('AliveMsg')
		&& it.contains('NM peer range')), errs(check_telemetry_frames(s)).str()
}

// REQ-TOPO-001: two differently-NAMED DBC messages at the SAME CAN id are one wire
// frame — two nodes each producing into one of them collide (ownership keyed by id).
fn test_frame_owner_keyed_by_can_id() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dupframe_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// FrameA and FrameB both at CAN id 0x120
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a b

BO_ 288 FrameA: 8 a
 SG_ A : 0|8@1+ (1,0) [0|255] "" b

BO_ 288 FrameB: 8 b
 SG_ B : 0|8@1+ (1,0) [0|255] "" a
') or {
		panic(err)
	}
	mut s := System{
		dir:   dir
		buses: [
			Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'compute.dbc'
			},
		]
		nodes: [
			Node{
				name:  'a'
				buses: ['compute']
				view:  NodeView{
					produces:    {
						'can0': ['A']
					}
					local_buses: ['can0']
				}
			},
			Node{
				name:  'b'
				buses: ['compute']
				view:  NodeView{
					produces:    {
						'can0': ['B']
					}
					local_buses: ['can0']
				}
			},
		]
	}
	assert errs(check_frame_single_writer(s)).any(it.contains('one frame owner')
		&& it.contains('288')), errs(check_frame_single_writer(s)).str()
}

// REQ-TOPO-002: a host node with a node-local [[route]] builds WITHOUT trace
// (loom2v trace_host needs routes.len == 0), so its trace ids are not reserved.
fn test_host_route_disables_trace_reservation() {
	mut s := clean_system()
	for i in 0 .. 2 {
		s.nodes[i].view.is_threadx = false
		s.nodes[i].view.has_telemetry = false
		s.nodes[i].view.trace_on = true
		s.nodes[i].view.trace_bus = 'can0'
		s.nodes[i].view.trace_record_id = 0x7e5
		s.nodes[i].view.partition_count = 1
		s.nodes[i].view.has_route = true // a node-local route -> no host trace
		s.nodes[i].view.produces = map[string][]string{}
		s.nodes[i].view.consumes = map[string][]string{}
	}
	assert !errs(validate_system(s)).any(it.contains('trace record id 0x7e5')), errs(validate_system(s)).str()
}

// --- codex #141 round-21 fixes ---

// REQ-TOPO-002: a NUMERIC alive id does NOT exempt a same-id application frame —
// only a named-binding alive frame is legal in the range.
fn test_numeric_alive_does_not_exempt_app_frame() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_numalive_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a

BO_ 1297 SpeedFrame: 8 a
 SG_ Speed : 0|32@1+ (1,0) [0|4294967295] "" a
') or {
		panic(err)
	}
	mut s := System{
		dir:   dir
		buses: [
			Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'compute.dbc'
			},
		]
		nodes: [
			Node{
				name:  'a'
				buses: ['compute']
				view:  NodeView{
					has_nm:             true
					nm_enabled:         true
					nm_bus:             'can0'
					peers_lo:           0x500
					peers_hi:           0x53f
					alive:              0x511 // NUMERIC alive, not a DBC binding
					has_alive:          true
					alive_from_binding: false
					local_buses:        ['can0']
				}
			},
		]
	}
	// SpeedFrame at 0x511 is a real app frame colliding with the numeric alive id
	assert errs(check_telemetry_frames(s)).any(it.contains('SpeedFrame')
		&& it.contains('NM peer range')), errs(check_telemetry_frames(s)).str()
}

// REQ-TOPO-003: a declared bus DBC that cannot be parsed is a system error, not a
// silently-absent contract.
fn test_unreadable_bus_dbc_is_error() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_baddbc_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	mut s := System{
		dir:   dir
		buses: [
			Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'missing.dbc' // declared but does not exist
			},
		]
		nodes: [
			Node{
				name:  'a'
				buses: ['compute']
				view:  NodeView{
					local_buses: ['can0']
				}
			},
		]
	}
	assert errs(validate_system(s)).any(it.contains('cannot load declared DBC')
		&& it.contains('missing.dbc')), errs(validate_system(s)).str()
}

// --- codex #141 round-22 fixes ---

// REQ-TOPO-002: ISO-TP rx/tx ids include 0 (loom2v emits them as configured) —
// two nodes both defaulting/using rx_id = 0 collide on the wire.
fn test_isotp_id_zero_collides() {
	mut s := clean_system()
	s.nodes[0].view.isotp_conns = [
		IsotpConn{
			iface: 'can0'
			rx_id: 0
			tx_id: 0x701
		},
	]
	s.nodes[1].view.isotp_conns = [
		IsotpConn{
			iface: 'can0'
			rx_id: 0
			tx_id: 0x702
		},
	] // both rx at 0
	assert errs(validate_system(s)).any(it.contains('[[isotp]] diagnostic id 0x0')
		&& it.contains('collides')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: an ISO-TP rx id is reserved on its bus — a telemetry frame at the
// same id is misdelivered to the ISO-TP/UDS receiver.
fn test_isotp_rx_reserved_vs_telemetry() {
	mut s := clean_system()
	// node 0 is a host node with an isotp rx at 0x7e0 on can0
	s.nodes[0].view.isotp_conns = [
		IsotpConn{
			iface: 'can0'
			rx_id: 0x7e0
			tx_id: 0x7e1
		},
	]
	// node 1 transmits telemetry at 0x7e0 -> misrouted into the ISO-TP receiver
	s.nodes[1].view.has_telemetry = true
	s.nodes[1].view.telem_bus = 'can0'
	s.nodes[1].view.telem_id = 0x7e0
	assert errs(validate_system(s)).any(it.contains('telemetry id 0x7e0')
		&& it.contains('isotp rx (rx) id of "sysnode"')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: two nodes explicitly allocated trace = 0 share a trace id (0 is a
// valid, declared trace node id — tracked by presence, not != 0).
fn test_trace_id_zero_collides() {
	mut s := clean_system()
	s.nodes[0].trace = 0
	s.nodes[0].has_trace = true
	s.nodes[1].trace = 0
	s.nodes[1].has_trace = true
	assert errs(validate_system(s)).any(it.contains('trace node id 0') && it.contains('shared')), errs(validate_system(s)).str()
}

// --- codex #141 round-23 fixes ---

// REQ-TOPO-002: a produced application frame at a module RECEIVE id (here a trace
// node's cmd id 0x7e2) is routed into that module — reject it.
fn test_app_frame_on_module_rx_id_is_error() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_apprx_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// SpeedFrame at 0x7e2 (== the default trace cmd rx id)
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a b

BO_ 2018 SpeedFrame: 8 b
 SG_ Speed : 0|32@1+ (1,0) [0|4294967295] "" a
') or {
		panic(err)
	}
	mut s := System{
		dir:   dir
		buses: [
			Bus{
				name:      'compute'
				interface: 'can0'
				dbc:       'compute.dbc'
			},
		]
		nodes: [
			Node{
				name:  'tracer'
				buses: ['compute']
				view:  NodeView{
					is_threadx:      true
					comm_thread_on:  true
					has_telemetry:   true
					telem_bus:       'can0'
					telem_id:        0x7a0
					trace_on:        true
					trace_record_id: 0x7a1
					trace_rsp_id:    0x7a2
					trace_cmd_id:    0x7e2 // reserved rx
					consumes:        {
						'can0': ['Speed']
					}
					local_buses:     ['can0']
				}
			},
			Node{
				name:  'b'
				buses: ['compute']
				view:  NodeView{
					produces:    {
						'can0': ['Speed'] // SpeedFrame is at 0x7e2
					}
					local_buses: ['can0']
				}
			},
		]
	}
	assert errs(check_telemetry_frames(s)).any(it.contains('application frame "SpeedFrame"')
		&& it.contains('trace cmd (rx) id of "tracer"')), errs(check_telemetry_frames(s)).str()
}

// REQ-TOPO-002: a host node with ZERO partitions gets no trace (loom2v trace_host
// needs exactly one), so its trace ids are not reserved.
fn test_zero_partition_host_no_trace() {
	mut s := clean_system()
	for i in 0 .. 2 {
		s.nodes[i].view.is_threadx = false
		s.nodes[i].view.has_telemetry = false
		s.nodes[i].view.trace_on = true
		s.nodes[i].view.trace_bus = 'can0'
		s.nodes[i].view.trace_record_id = 0x7e5
		s.nodes[i].view.partition_count = 0 // zero partitions -> no host trace
		s.nodes[i].view.produces = map[string][]string{}
		s.nodes[i].view.consumes = map[string][]string{}
	}
	assert !errs(validate_system(s)).any(it.contains('trace record id 0x7e5')), errs(validate_system(s)).str()
}

// --- codex #141 round-24 fixes ---

// REQ-TOPO-002: host trace eligibility counts FB-BEARING partitions (loom2v's
// m.part.by_part), so a second partition with no FB does not disqualify trace.
fn test_partition_count_is_fb_bearing() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_fbpart_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// two partitions; only "app" hosts an FB -> FB-partition count = 1
	os.write_file(os.join_path(dir, 'n.toml'), '
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "ctrl"
[[partition]]
name = "idle"
core = 0
  [[partition.thread]]
  name = "spin" # trailing comment (vlang/v#27684)
[[fb]]
name   = "Dashboard"
thread = "ctrl" # trailing comment (vlang/v#27684)
') or {
		panic(err)
	}
	view := load_node(os.join_path(dir, 'n.toml')) or { panic(err) }
	assert view.partition_count == 1, 'only the FB-bearing partition counts, got ${view.partition_count}'
}

// REQ-TOPO-002: an empty `route = []` is NOT a trace blocker (loom2v uses
// m.routes.len > 0).
fn test_empty_route_not_a_trace_blocker() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_emptyroute_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'n.toml'), '
route = []
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "ctrl" # trailing comment (vlang/v#27684)
') or {
		panic(err)
	}
	view := load_node(os.join_path(dir, 'n.toml')) or { panic(err) }
	assert !view.has_route, 'an empty route array is not a route'
}

// ===== DISSOLUTION model tests (merged from #142) =====

// a clean dissolved system: two cross-node signals declared at system scope,
// nodes carry only FB read/write intent. `a` produces Speed + reads Rpm; `b`
// produces Rpm + reads Speed.
fn clean_dissolved() System {
	// a bus carrying cross-node signals needs a DBC; write one that matches the
	// signals (SpeedFrame from a, RpmFrame from b) to a stable temp path.
	dir := os.join_path(os.temp_dir(), 'sysmodel_clean_dissolved')
	os.mkdir_all(dir) or {}
	os.write_file(os.join_path(dir, 'compute.dbc'), good_dbc) or {}
	return System{
		dir:     dir
		buses:   [
			Bus{
				name:           'compute'
				interface:      'can0'
				dbc:            'compute.dbc'
				has_nm_cluster: true
				nm_peers_lo:    0x500
				nm_peers_hi:    0x53f
			},
		]
		signals: [
			SysSignal{
				name:     'Speed'
				producer: 'a'
				bus:      'compute'
				frame:    'SpeedFrame'
				fields:   {
					'kph': 'u16'
				}
			},
			SysSignal{
				name:     'Rpm'
				producer: 'b'
				bus:      'compute'
				frame:    'RpmFrame'
				fields:   {
					'rpm': 'u16'
				}
			},
		]
		nodes:   [
			Node{
				name:         'a'
				buses:        ['compute']
				nm:           0x11
				has_nm_alloc: true
				trace:        1
				view:         NodeView{
					fb_writes:     ['Speed']
					fb_reads:      ['Rpm']
					is_threadx:    true
					has_telemetry: true
					telem_bus:     'can0'
					telem_id:      0x7e0 // CpuLoad is always sent; a real id avoids the effective-0 clash
				}
			},
			Node{
				name:         'b'
				buses:        ['compute']
				nm:           0x13
				has_nm_alloc: true
				trace:        2
				view:         NodeView{
					fb_writes:     ['Rpm']
					fb_reads:      ['Speed']
					is_threadx:    true
					has_telemetry: true
					telem_bus:     'can0'
					telem_id:      0x7e2
				}
			},
		]
	}
}

// dissolved_with_dbc writes a compute.dbc whose two frames match clean_dissolved
// (SpeedFrame from a, RpmFrame from b) and points the system at it.
fn dissolved_with_dbc(dir string, dbc string) System {
	os.mkdir_all(dir) or { panic(err) }
	os.write_file(os.join_path(dir, 'compute.dbc'), dbc) or { panic(err) }
	mut s := clean_dissolved()
	s.dir = dir
	s.buses[0].dbc = 'compute.dbc'
	return s
}

const good_dbc = 'VERSION ""

BU_: a b

BO_ 288 SpeedFrame: 8 a
 SG_ Speed : 0|16@1+ (1,0) [0|65535] "" b

BO_ 289 RpmFrame: 8 b
 SG_ Rpm : 0|16@1+ (1,0) [0|65535] "" a
'

// REQ-TOPO-003: a DBC signal name that appears in more than one frame is
// ambiguous — loom2v resolves by name to the first match.
fn test_dbc_ambiguous_signal_name() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_amb_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	// "Speed" appears in BOTH SpeedFrame and OtherFrame
	amb := 'VERSION ""\nBU_: a b\nBO_ 288 SpeedFrame: 8 a\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" b\nBO_ 290 OtherFrame: 8 a\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" b\nBO_ 289 RpmFrame: 8 b\n SG_ Rpm : 0|16@1+ (1,0) [0|65535] "" a\n'
	s := dissolved_with_dbc(dir, amb)
	assert errs(check_dbc_conformance(s)).any(it.contains('appears in 2 frames'))
}

fn test_dbc_conformance_clean() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_ok_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	s := dissolved_with_dbc(dir, good_dbc)
	issues := check_dbc_conformance(s)
	assert errs(issues).len == 0, 'clean DBC flagged: ${errs(issues)}'
}

// REQ-TOPO-003: a signal whose fields overflow the DBC frame's payload.
fn test_dbc_fields_overflow() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_ovf_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut s := dissolved_with_dbc(dir, good_dbc)
	// widen Speed to 9x u64 = 576 bits, past the 8-byte (64-bit) frame
	s.signals[0].fields = {
		'a': 'u64'
		'b': 'u64'
		'c': 'u64'
		'd': 'u64'
		'e': 'u64'
		'f': 'u64'
		'g': 'u64'
		'h': 'u64'
		'i': 'u64'
	}
	assert errs(check_dbc_conformance(s)).any(it.contains('need') && it.contains('only 8 bytes'))
}

// REQ-TOPO-003: an application DBC frame id inside the NM peer range would be
// consumed as an NM frame (loom2v arms the whole range as the NM receiver).
fn test_dbc_frame_id_in_nm_range() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_nm_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	// SpeedFrame id 0x510 falls in the cluster's peers range [0x500,0x53f]
	bad := 'VERSION ""\nBU_: a b\nBO_ 1296 SpeedFrame: 8 a\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" b\nBO_ 289 RpmFrame: 8 b\n SG_ Rpm : 0|16@1+ (1,0) [0|65535] "" a\n'
	s := dissolved_with_dbc(dir, bad) // clean_dissolved's bus has peers [0x500,0x53f]
	assert errs(check_dbc_conformance(s)).any(it.contains('falls in the NM peer range'))
}

// REQ-TOPO-003: a signal whose frame is not defined in the bus DBC.
fn test_dbc_frame_missing() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_miss_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	// DBC has only SpeedFrame; RpmFrame is absent
	s := dissolved_with_dbc(dir,
		'VERSION ""\nBU_: a b\nBO_ 288 SpeedFrame: 8 a\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" b\n')
	assert errs(check_dbc_conformance(s)).any(it.contains('frame "RpmFrame" is not defined'))
}

// REQ-TOPO-003: a multiplexed DBC SG_ has no codec support in this model.
fn test_dbc_multiplexed_signal_rejected() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_mux_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	// Speed is multiplexed (m0) in SpeedFrame
	mux := 'VERSION ""\nBU_: a b\nBO_ 288 SpeedFrame: 8 a\n SG_ Mode M : 16|8@1+ (1,0) [0|255] "" b\n SG_ Speed m0 : 0|16@1+ (1,0) [0|65535] "" b\nBO_ 289 RpmFrame: 8 b\n SG_ Rpm : 0|16@1+ (1,0) [0|65535] "" a\n'
	s := dissolved_with_dbc(dir, mux)
	assert errs(check_dbc_conformance(s)).any(it.contains('is multiplexed'))
}

// REQ-TOPO-003: the DBC transmitter disagreeing with the declared producer.
fn test_dbc_sender_mismatch() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_snd_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	// SpeedFrame sender is 'b' in the DBC but producer is 'a' in system.toml
	bad := 'VERSION ""\nBU_: a b\nBO_ 288 SpeedFrame: 8 b\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" a\nBO_ 289 RpmFrame: 8 b\n SG_ Rpm : 0|16@1+ (1,0) [0|65535] "" a\n'
	s := dissolved_with_dbc(dir, bad)
	assert errs(check_dbc_conformance(s)).any(it.contains('transmitted by "b"')
		&& it.contains('producer "a"'))
}

// REQ-TOPO-003: a BO_ sender that is not in the DBC's own BU_ roster — a dangling
// node reference (an invalid DBC). This is the "renamed the node ONLY in BU_"
// slip: the sender still equals the producer, so the mismatch check above passes,
// but the BU_ list no longer declares it.
fn test_dbc_sender_not_in_bu() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_bu_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	// SpeedFrame sender 'a' still matches producer 'a', but BU_ lists only 'b'.
	bad := 'VERSION ""\nBU_: b\nBO_ 288 SpeedFrame: 8 a\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" b\nBO_ 289 RpmFrame: 8 b\n SG_ Rpm : 0|16@1+ (1,0) [0|65535] "" b\n'
	s := dissolved_with_dbc(dir, bad)
	assert errs(check_dbc_conformance(s)).any(it.contains('transmitted by "a"')
		&& it.contains('BU_ list'))
}

// REQ-TOPO-003: an SG_ receiver node not in BU_ — the RX-side twin of the sender
// case. candb keeps the SG_ receiver list, so a dangling receiver is caught even
// though blobly derives consumers from FB reads (the DBC RX list is otherwise
// informational).
fn test_dbc_receiver_not_in_bu() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_rx_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	// Speed's receiver 'z' is in no BU_ entry (BU_ lists a b); senders are valid.
	bad := 'VERSION ""\nBU_: a b\nBO_ 288 SpeedFrame: 8 a\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" z\nBO_ 289 RpmFrame: 8 b\n SG_ Rpm : 0|16@1+ (1,0) [0|65535] "" a\n'
	s := dissolved_with_dbc(dir, bad)
	assert errs(check_dbc_conformance(s)).any(it.contains('received by "z"')
		&& it.contains('BU_ list'))
}

// REQ-TOPO-003: a signal whose name is not an SG_ in its DBC frame.
fn test_dbc_signal_not_in_frame() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_sg_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	// SpeedFrame carries SG_ "Velocity", not "Speed"
	bad := 'VERSION ""\nBU_: a b\nBO_ 288 SpeedFrame: 8 a\n SG_ Velocity : 0|16@1+ (1,0) [0|65535] "" b\nBO_ 289 RpmFrame: 8 b\n SG_ Rpm : 0|16@1+ (1,0) [0|65535] "" a\n'
	s := dissolved_with_dbc(dir, bad)
	assert errs(check_dbc_conformance(s)).any(it.contains('has no SG_ named "Speed"'))
}

// REQ-TOPO-003: a signal whose field width disagrees with the DBC SG_ width.
fn test_dbc_signal_width_mismatch() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_w_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	// Speed's field is u16 (16 bits) but the DBC SG_ is 8 bits
	bad := 'VERSION ""\nBU_: a b\nBO_ 288 SpeedFrame: 8 a\n SG_ Speed : 0|8@1+ (1,0) [0|255] "" b\nBO_ 289 RpmFrame: 8 b\n SG_ Rpm : 0|16@1+ (1,0) [0|65535] "" a\n'
	s := dissolved_with_dbc(dir, bad)
	assert errs(check_dbc_conformance(s)).any(it.contains('16 bits') && it.contains('8 bits'))
}

// REQ-TOPO-003: a u16 field on a SIGNED DBC SG_ (or vice versa).
fn test_dbc_signedness_mismatch() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_sgn_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	// SpeedFrame's SG_ is SIGNED (@1-) but the field is u16
	bad := 'VERSION ""\nBU_: a b\nBO_ 288 SpeedFrame: 8 a\n SG_ Speed : 0|16@1- (1,0) [0|65535] "" b\nBO_ 289 RpmFrame: 8 b\n SG_ Rpm : 0|16@1+ (1,0) [0|65535] "" a\n'
	s := dissolved_with_dbc(dir, bad)
	assert errs(check_dbc_conformance(s)).any(it.contains('field is unsigned but DBC SG_')
		&& it.contains('signed'))
}

// REQ-TOPO-004: a node whose derived alive id (peers base + nm) falls outside
// the cluster range would be ignored by NM.
fn test_dissolved_alive_out_of_range() {
	mut s := clean_dissolved()
	s.nodes[0].nm = 0x40 // 0x500 + 0x40 = 0x540, outside [0x500,0x53f]
	assert errs(validate_system_gen(s)).any(it.contains('outside the cluster range'))
}

// REQ-TOPO-003: a bus carrying cross-node signals must declare a DBC.
fn test_dissolved_bus_without_dbc() {
	mut s := clean_dissolved()
	s.buses[0].dbc = '' // no DBC, but it carries Speed/Rpm
	assert errs(check_dbc_conformance(s)).any(it.contains('carries cross-node signals but declares no `dbc`'))
}

fn test_dissolved_clean() {
	issues := validate_system_gen(clean_dissolved())
	assert errs(issues).len == 0, 'clean dissolved system flagged: ${errs(issues)}'
}

// REQ-TOPO-001: a consumer that reads a signal but isn't on its bus.
fn test_dissolved_consumer_off_bus() {
	mut s := clean_dissolved()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[1].buses = ['edge'] // b reads Speed (on compute) but sits on edge
	assert errs(validate_system_gen(s)).any(it.contains('consumer "b"')
		&& it.contains('not on its bus'))
}

// REQ-TOPO-001: a cross-node RX signal read from two partitions (SPSC violation).
fn test_dissolved_cross_partition_reader() {
	mut s := clean_dissolved()
	// domain (b) reads Speed from two partitions
	s.nodes[1].view.read_partitions = {
		'Speed': ['ctlA', 'ctlB']
	}
	assert errs(validate_system_gen(s)).any(it.contains('read from 2 partitions'))
}

// REQ-TOPO-003: a bus DBC with two BO_ sharing one CAN id is ambiguous — the
// generator would emit both transmitters under one wire id.
fn test_dissolved_dbc_duplicate_frame_id_is_error() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dupid_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// SpeedFrame and Shadow both at id 288
	dup := 'VERSION ""

BU_: a b

BO_ 288 SpeedFrame: 8 a
 SG_ Speed : 0|16@1+ (1,0) [0|65535] "" b

BO_ 288 Shadow: 8 b
 SG_ Ghost : 0|16@1+ (1,0) [0|65535] "" a

BO_ 289 RpmFrame: 8 b
 SG_ Rpm : 0|16@1+ (1,0) [0|65535] "" a
'
	s := dissolved_with_dbc(dir, dup)
	assert errs(check_dbc_conformance(s)).any(it.contains('share CAN id 0x120')), errs(check_dbc_conformance(s)).str()
}

// REQ-TOPO-001: a cross-node signal declared twice.
fn test_dissolved_duplicate_signal_name() {
	mut s := clean_dissolved()
	s.signals << SysSignal{
		name:     'Speed'
		producer: 'a'
		bus:      'compute'
		frame:    'SpeedFrame'
	}
	assert errs(validate_system_gen(s)).any(it.contains('declared more than once'))
}

// REQ-TOPO-001: two signals sharing a frame disagree on cycle_ms.
fn test_dissolved_frame_cycle_conflict() {
	mut s := clean_dissolved()
	// make Rpm ride the same frame as Speed, same producer, but a different cycle
	s.signals[0].producer = 'a'
	s.signals[0].cycle_ms = 100
	s.signals[1].producer = 'a'
	s.signals[1].frame = 'SpeedFrame'
	s.signals[1].cycle_ms = 50
	s.nodes[0].view.fb_writes = ['Speed', 'Rpm'] // a produces both
	s.nodes[1].view.fb_writes = []
	assert errs(validate_system_gen(s)).any(it.contains('disagree on cycle'))
}

// REQ-TOPO-001: a shared frame where one signal omits cycle_ms (defaults to 100)
// and another sets 50 — the effective cadences conflict.
fn test_dissolved_frame_effective_cycle_conflict() {
	mut s := clean_dissolved()
	s.signals[0].producer = 'a'
	s.signals[0].cycle_ms = 0 // -> effective 100
	s.signals[1].producer = 'a'
	s.signals[1].frame = 'SpeedFrame'
	s.signals[1].cycle_ms = 50
	s.nodes[0].view.fb_writes = ['Speed', 'Rpm']
	s.nodes[1].view.fb_writes = []
	assert errs(validate_system_gen(s)).any(it.contains('disagree on cycle')
		&& it.contains('effective'))
}

// REQ-TOPO-001: two signals in one DBC frame from different producers contend.
fn test_dissolved_frame_owner_collision() {
	mut s := clean_dissolved()
	s.signals[1].frame = 'SpeedFrame' // Rpm(prod b) shares SpeedFrame with Speed(prod a)
	assert errs(validate_system_gen(s)).any(it.contains('one frame owner per bus'))
}

// REQ-TOPO-004: a host (non-threadx) node on an NM cluster gets a dead [nm].
fn test_dissolved_host_node_nm_dead() {
	mut s := clean_dissolved()
	s.nodes[0].view.is_threadx = false // a host node
	assert errs(validate_system_gen(s)).any(it.contains('not a threadx target')
		&& it.contains('no runtime'))
}

// REQ-TOPO-006: a multi-bus node that gateways NO route is rejected (its extra
// buses would be silently unwired). A multi-bus node is only legal as a gateway.
fn test_dissolved_multibus_nongateway_rejected() {
	mut s := clean_dissolved()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[0].buses = ['compute', 'edge']
	assert errs(validate_system_gen(s)).any(it.contains('gateways no route'))
}

// REQ-TOPO-006: a multi-bus node IS accepted when it is a declared route gateway
// (P2a). Here sysnode gateways the signal `kph`... — a signal route compute->edge.
fn test_dissolved_multibus_gateway_accepted() {
	mut s := clean_dissolved()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[0].buses = ['compute', 'edge'] // sysnode is the gateway
	// a consumer on edge so the route is well-formed end to end
	s.nodes << Node{
		name:         'zone'
		buses:        ['edge']
		nm:           0x15
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace:        4
		view:         NodeView{
			fb_reads: [s.signals[0].name]
		}
	}
	s.routes << Route{
		gateway: s.nodes[0].name
		signal:  s.signals[0].name
		from:    'compute'
		to:      'edge'
	}
	e := errs(validate_system_gen(s))
	assert !e.any(it.contains('gateways no route')), 'a route gateway is allowed multi-bus: ${e}'
	assert !e.any(it.contains('exactly one bus')), e.str()
}

// REQ-TOPO-012: the routed cell has a single writer. A node on the destination bus
// whose FB also writes the routed signal is a second writer — rejected.
fn test_route_dest_double_writer_rejected() {
	mut s := clean_dissolved()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[0].buses = ['compute', 'edge'] // 'a' gateways Speed
	s.nodes << Node{
		name:         'zone'
		buses:        ['edge']
		nm:           0x15
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace:        4
		view:         NodeView{
			fb_writes: ['Speed'] // a SECOND writer of the routed signal on edge
		}
	}
	s.routes << Route{
		gateway: 'a'
		signal:  'Speed'
		from:    'compute'
		to:      'edge'
	}
	assert errs(validate_system_gen(s)).any(it.contains('single writer')
		|| it.contains('single-writer') || it.contains('one writer'))
}

// REQ-TOPO-011: routes that form a bus cycle for one signal are rejected (the
// value would recirculate forever).
fn test_route_cycle_rejected() {
	mut s := clean_dissolved()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[0].buses = ['compute', 'edge']
	s.routes << Route{
		gateway: 'a'
		signal:  'Speed'
		from:    'compute'
		to:      'edge'
	}
	s.routes << Route{
		gateway: 'a'
		signal:  'Speed'
		from:    'edge'
		to:      'compute'
	}
	assert errs(validate_system_gen(s)).any(it.contains('cycle'))
}

// REQ-TOPO-001: a cross-node signal must carry EXACTLY ONE field (loom2v's
// bridge serializes only the first value field per DBC signal).
fn test_dissolved_multifield_signal() {
	mut s := clean_dissolved()
	s.signals[0].fields = {
		'kph': 'u16'
		'mph': 'u16'
	}
	assert errs(validate_system_gen(s)).any(it.contains('value fields')
		&& it.contains('carries exactly one'))
}

// REQ-TOPO-005: a node with no NM allocation (the generator always emits [nm]).
fn test_dissolved_node_without_nm_alloc() {
	mut s := clean_dissolved()
	s.nodes[0].has_nm_alloc = false
	assert errs(validate_system_gen(s)).any(it.contains('must allocate an `nm`'))
}

// REQ-TOPO-001: a signal field must be a fixed scalar type (no heap types).
fn test_dissolved_non_scalar_field() {
	mut s := clean_dissolved()
	s.signals[0].fields = {
		'kph': 'string'
	}
	assert errs(validate_system_gen(s)).any(it.contains('unsupported type "string"'))
}

// REQ-TOPO-001: a NON-producer node writing a declared signal.
fn test_dissolved_nonproducer_write_rejected() {
	mut s := clean_dissolved()
	s.nodes[1].view.fb_writes = ['Rpm', 'Speed'] // b writes Speed, but a is the producer
	assert errs(validate_system_gen(s)).any(it.contains('only the producer may write'))
}

// REQ-TOPO-002: an OMITTED telemetry id defaults to 0 and the CpuLoad frame is
// always sent, so two id-less threadx nodes both transmit at CAN id 0 — the
// effective ids collide even though neither authored one.
fn test_dissolved_omitted_telemetry_ids_collide_at_zero() {
	mut s := clean_dissolved()
	s.nodes[0].view.telem_id = 0
	s.nodes[1].view.telem_id = 0
	assert errs(validate_system_gen(s)).any(it.contains('telemetry id 0x0')
		&& it.contains('single-writer')), errs(validate_system_gen(s)).str()
}

// REQ-TOPO-005: a [[route]] authored in a partial is uncheckable wiring.
fn test_dissolved_partial_authors_route() {
	mut s := clean_dissolved()
	s.nodes[0].view.authored_routes = true
	assert errs(validate_system_gen(s)).any(it.contains('authors bus wiring')
		&& it.contains('[[route]]'))
}

// REQ-TOPO-005: a partial node that authors bus wiring (bypasses the checks).
fn test_dissolved_partial_authors_wiring() {
	mut s := clean_dissolved()
	s.nodes[0].view.local_buses = ['can0'] // authored a [bus.can0]
	assert errs(validate_system_gen(s)).any(it.contains('authors bus wiring'))
}

// REQ-TOPO-005: a partial authoring a bus-endpoint [[signal]] with NO [bus.*].
fn test_dissolved_partial_signal_without_bus_table() {
	mut s := clean_dissolved()
	s.nodes[0].view.authored_signals = true // authored a [[signal]] (no [bus])
	assert errs(validate_system_gen(s)).any(it.contains('authors bus wiring')
		&& it.contains('[[signal]]'))
}

// REQ-TOPO-005: the producer's FBs must actually write the signal.
fn test_dissolved_producer_doesnt_write() {
	mut s := clean_dissolved()
	s.nodes[0].view.fb_writes = [] // 'a' declared producer of Speed but writes nothing
	assert errs(validate_system_gen(s)).any(it.contains('has no FB that writes it'))
}

// REQ-TOPO-001: a signal whose producer isn't a declared node.
fn test_dissolved_producer_not_a_node() {
	mut s := clean_dissolved()
	s.signals[0].producer = 'ghost'
	assert errs(validate_system_gen(s)).any(it.contains('producer "ghost" is not a declared node'))
}

// REQ-TOPO-001: the producer must sit on the signal's bus.
fn test_dissolved_producer_off_bus() {
	mut s := clean_dissolved()
	s.nodes[0].buses = [] // 'a' produces Speed on compute but isn't on it
	assert errs(validate_system_gen(s)).any(it.contains('does not sit on its bus'))
}

// REQ-TOPO-001: a producer that also reads its own bus-published signal.
fn test_dissolved_producer_reads_own_signal() {
	mut s := clean_dissolved()
	s.nodes[0].view.fb_reads = ['Rpm', 'Speed'] // a produces Speed AND reads it
	assert errs(validate_system_gen(s)).any(it.contains('also reads it'))
}

// REQ-TOPO-001: a signal declared with no fields (loom2v rejects an empty map).
fn test_dissolved_signal_no_fields() {
	mut s := clean_dissolved()
	s.signals[0].fields = map[string]string{}
	assert errs(validate_system_gen(s)).any(it.contains('has no value field'))
}

// REQ-TOPO-004: a threadx+telemetry cluster member that produces/consumes NO
// system signal has no bridge, so loom2v emits no comm thread — its generated
// [nm] never runs (dead NM). Telemetry alone is not a bridge.
fn test_dissolved_signalless_cluster_member_is_error() {
	mut s := clean_dissolved()
	s.nodes << Node{
		name:         'c'
		buses:        ['compute']
		nm:           0x15
		has_nm_alloc: true
		trace:        3
		view:         NodeView{
			is_threadx:    true
			has_telemetry: true
			// no fb_reads / fb_writes: not a producer, reads nothing -> no bridge
		}
	}
	assert errs(validate_system_gen(s)).any(it.contains('node "c"')
		&& it.contains('produces/consumes no system signal')), errs(validate_system_gen(s)).str()
}

// REQ-TOPO-001: a lone `valid` field has no value for the bridge to serialize.
fn test_dissolved_sole_valid_field_rejected() {
	mut s := clean_dissolved()
	s.signals[0].fields = {
		'valid': 'bool'
	}
	assert errs(validate_system_gen(s)).any(it.contains('has no value field'))
}

// REQ-TOPO-002: a telemetry id equal to a DBC application frame aliases two
// different frames on the wire.
fn test_dissolved_telemetry_aliases_dbc_frame_is_error() {
	mut s := clean_dissolved()
	s.nodes[0].view.telem_id = 0x120 // == SpeedFrame (288) in good_dbc
	assert errs(validate_system_gen(s)).any(it.contains('aliases DBC application frame "SpeedFrame"')), errs(validate_system_gen(s)).str()
}

// REQ-TOPO-002: two nodes with the same explicit telemetry id on one bus are an
// unowned multi-writer (the comm threads both transmit that frame).
fn test_dissolved_telemetry_id_collision_is_error() {
	mut s := clean_dissolved()
	s.nodes[0].view.telem_id = 0x7e0
	s.nodes[1].view.telem_id = 0x7e0 // same id as node a
	assert errs(validate_system_gen(s)).any(it.contains('telemetry id 0x7e0')
		&& it.contains('single-writer')), errs(validate_system_gen(s)).str()
}

// REQ-TOPO-002: a node's telemetry id and detail_id must differ.
fn test_dissolved_telemetry_id_equals_detail_is_error() {
	mut s := clean_dissolved()
	s.nodes[0].view.telem_id = 0x7e0
	s.nodes[0].view.telem_detail_id = 0x7e0 // same as its own id
	assert errs(validate_system_gen(s)).any(it.contains('collides with its own')), errs(validate_system_gen(s)).str()
}

// REQ-TOPO-001: the producer writing a signal from two FBs (two publishers).
fn test_dissolved_two_writers_rejected() {
	mut s := clean_dissolved()
	s.nodes[0].view.fb_writes = ['Speed', 'Speed'] // two handlers write Speed
	assert errs(validate_system_gen(s)).any(it.contains('writes it from 2 FBs'))
}

// REQ-TOPO-001: a node whose bus is not declared in system.toml.
fn test_dissolved_undeclared_bus() {
	mut s := clean_dissolved()
	s.nodes[0].buses = ['ghostbus']
	s.signals[0].bus = 'ghostbus' // so membership passes textually
	assert errs(validate_system_gen(s)).any(it.contains('bus "ghostbus" is not declared'))
}

// REQ-TOPO-001: an FB reading a signal the system never declared.
fn test_dissolved_unknown_read_is_error() {
	mut s := clean_dissolved()
	s.nodes[0].view.fb_reads = ['Rpm', 'Ghost']
	assert errs(validate_system_gen(s)).any(it.contains('reads "Ghost"')
		&& it.contains('neither a system signal nor a node-local'))
}

// REQ-TOPO-005/001: a NODE-LOCAL signal (an io point) is the node's application,
// not bus wiring — an FB may read/write it, and it does NOT trip the internals-only
// or unknown-signal checks (a gpio/adc/pwm node in the dissolution).
fn test_dissolved_local_io_signal_accepted() {
	mut s := clean_dissolved()
	s.nodes[0].view.local_signals = ['UserButton', 'LedGreen']
	s.nodes[0].view.fb_reads = ['Rpm', 'UserButton'] // Rpm = system, UserButton = local io
	s.nodes[0].view.fb_writes = ['LedGreen'] // a local io output
	// neither the local read nor the local write is an error
	assert !errs(validate_system_gen(s)).any(it.contains('UserButton'))
	assert !errs(validate_system_gen(s)).any(it.contains('LedGreen'))
}

// REQ-TOPO-001: a signal no other node reads is a warning, not an error.
fn test_dissolved_unread_signal_is_warning() {
	mut s := clean_dissolved()
	s.nodes[1].view.fb_reads = [] // nobody reads Speed anymore
	issues := validate_system_gen(s)
	assert errs(issues).len == 0
	assert issues.any(it.severity == .warning && it.msg.contains('Speed')
		&& it.msg.contains('read by no other node'))
}

// REQ-TOPO-001: a value field ALONGSIDE `valid` is the supported shape (valid is
// metadata, excluded from the wire) — it must NOT be rejected.
fn test_dissolved_value_plus_valid_ok() {
	mut s := clean_dissolved()
	s.signals[0].fields = {
		'kph':   'u16'
		'valid': 'bool'
	}
	assert !errs(validate_system_gen(s)).any(it.contains('field') || it.contains('bits')), 'value+valid is valid: ${errs(validate_system_gen(s))}'
}

// codex #142 round 10: loom2v spawns partition_telem() on the HOST target too
// (not just threadx), so two host telemetry nodes sharing an id collide.
fn test_host_telemetry_id_collision_gen() {
	mut s := clean_dissolved()
	for i in 0 .. 2 {
		s.nodes[i].view.is_threadx = false // host target
		s.nodes[i].view.telem_id = 0x7e0 // same id on the same bus
	}
	assert errs(check_telemetry_frames(s)).any(it.contains('telemetry id 0x7e0')
		&& it.contains('single-writer')), errs(check_telemetry_frames(s)).str()
}

// codex parity (#141 round 11): loom2v's parse_telemetry defaults an omitted
// `enabled` to FALSE — [telemetry] with a bus but no enabled key does not give a
// threadx node its telemetry channel.
fn test_telemetry_enabled_defaults_false_gen() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_tenon_gen_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'n.toml'), '
[[partition]]
name = "app"
core = 0
  [[partition.thread]]
  name = "t" # trailing comment (vlang/v#27684)
[target]
kind    = "threadx"
tick_ms = 1
[telemetry]
bus = "can0"
') or {
		panic(err)
	}
	doc := toml.parse_file(os.join_path(dir, 'n.toml')) or { panic(err) }
	view := parse_node_view(doc)
	assert !view.has_telemetry, 'omitted [telemetry].enabled must default to false (loom2v parse_telemetry)'
}
