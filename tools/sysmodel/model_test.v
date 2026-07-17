module sysmodel

import os

// REQ-TOPO-005 is method = "analysis" (the system-sourced-generation architecture,
// argued in docs/multi-node.md) — these validator tests exercise cross-node checks,
// not that generation analysis, so they must NOT claim to verify it by test.
// @verifies REQ-TOPO-001, REQ-TOPO-002, REQ-TOPO-004, REQ-TOPO-006

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
				name:  'sysnode'
				buses: ['compute']
				nm:    0x11
				has_nm_alloc: true
				nm_alloc_ok:  true
				trace: 1
				view:  NodeView{
					produces:  {
						'can0': ['Speed']
					}
					consumes:  {
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
				name:  'domain'
				buses: ['compute']
				nm:    0x13
				has_nm_alloc: true
				nm_alloc_ok:  true
				trace: 2
				view:  NodeView{
					produces:  {
						'can0': ['Rpm']
					}
					consumes:  {
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

// REQ-TOPO-001: a produced signal nobody consumes is a WARNING, not an error.
fn test_unused_producer_is_warning_only() {
	mut s := clean_system()
	s.nodes[0].view.produces['can0'] = ['Speed', 'Spare']
	issues := validate_system(s)
	assert errs(issues).len == 0, 'unused producer should not be an error: ${errs(issues)}'
	assert issues.any(it.severity == .warning && it.msg.contains('Spare')), 'expected Spare warning'
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
	assert errs(issues).any(it.contains('alive id 0x600') && it.contains('outside its cluster range')), errs(issues).str()
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
		name:  'zone'
		buses: ['edge']
		nm:    0x20
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace: 3
		view:  NodeView{
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
	// add the route -> it is WELL-FORMED (suppresses the raw missing-producer gap)
	// but P1 does not GENERATE cross-bus routing, so the route itself is rejected:
	// a clean verdict would wrongly imply a forwarder exists at runtime.
	s.routes << Route{
		gateway: 'sysnode'
		signal:  'Speed'
		from:    'compute'
		to:      'edge'
	}
	e := errs(validate_system(s))
	assert !e.any(it.contains('Speed') && it.contains('no node transmits')), 'a well-formed route suppresses the raw missing-producer gap'
	assert e.any(it.contains('not generated in P1')), 'but the ungenerated route is itself rejected: ${e}'
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

// REQ-TOPO-001: two nodes transmitting the SAME frame (different signals into
// one PDU) contend on the wire even though each signal has one writer.
fn test_frame_single_writer_is_error() {
	mut s := clean_system()
	// authored spellings differ but loom2v snake()-normalizes both to the SAME DBC
	// PDU, so this is still one frame with two writers.
	s.nodes[0].view.tx_frames['can0'] = ['StatusFrame']
	s.nodes[1].view.tx_frames['can0'] = ['status_frame'] // same PDU, different spelling
	issues := validate_system(s)
	assert errs(issues).any(it.contains('frame "status_frame"') && it.contains('one frame owner')), errs(issues).str()
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
		name:  'zone'
		buses: ['edge']
		nm:    0x20
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace: 3
		view:  NodeView{
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
		name:  'third'
		buses: ['compute']
		nm:    0x15
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace: 4
		view:  NodeView{
			has_nm:        true
			nm_enabled:  true
			nm_node:       0x15
			has_nm_node:   true
			nm_node_ok:  true
			alive:         0x515
			has_alive:   true
			peers_lo:      0x500
			peers_hi:      0x53f
			local_buses:   ['can0']
			nm_has_timeout: true
			nm_timeout_ms: 500 // conflicts with domain's 300
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
') or { panic(err) }
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
') or { panic(err) }
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
') or { panic(err) }
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
		name:  'zone'
		buses: ['edge']
		nm:    0x21
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace: 3
		view:  NodeView{
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
		name:  'zone'
		buses: ['edge']
		nm:    0x21
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace: 3
		view:  NodeView{
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
') or { panic(err) }
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

// REQ-TOPO-005: a threadx node with no [telemetry] bus can't be generated.
fn test_threadx_requires_telemetry() {
	mut s := clean_system()
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.has_telemetry = false
	assert errs(validate_system(s)).any(it.contains('no [telemetry] bus'))
}

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
	assert errs(validate_system(s)).any(it.contains('alive binding "AliveMsg"') && it.contains('resolves to one CAN id'))
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
') or { panic(err) }
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
		name:  'zone'
		buses: ['edge']
		nm:    0x21
		has_nm_alloc: true
		nm_alloc_ok:  true
		trace: 3
		view:  NodeView{
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
') or { panic(err) }
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
') or { panic(err) }
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
') or { panic(err) }
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
') or { panic(err) }
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
') or { panic(err) }
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
') or { panic(err) }
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
') or { panic(err) }
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
') or { panic(err) }
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
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.nm_bus = 'can1' // differs from the telemetry bus
	assert errs(validate_system(s)).any(it.contains('[nm].bus "can1"')
		&& it.contains('[telemetry].bus "can0"')), errs(validate_system(s)).str()
}

// REQ-TOPO-005: loom2v's baremetal superloop panics for any external/bus signal
// (no comm bridge), so a baremetal node with bus-facing signals is not buildable.
fn test_baremetal_with_bus_signal_is_error() {
	mut s := clean_system()
	s.nodes[0].view.is_baremetal = true // node produces Speed on can0 (a bus signal)
	assert errs(validate_system(s)).any(it.contains('target is baremetal')
		&& it.contains('bus-facing signals')), errs(validate_system(s)).str()
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
		return // no echo to probe with; skip rather than fail on an odd host
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
		s.nodes[i].view.has_telemetry = true
		s.nodes[i].view.telem_bus = 'can0'
		s.nodes[i].view.nm_bus = 'can0'
		s.nodes[i].view.telem_id = 0 // both omit -> effective 0
	}
	assert errs(validate_system(s)).any(it.contains('telemetry id 0x0')
		&& it.contains('single-writer')), errs(validate_system(s)).str()
}

// REQ-TOPO-005: loom2v's threadx FDCAN backend is classic-only and panics for an
// fd = true telemetry bus.
fn test_threadx_fd_telemetry_bus_is_error() {
	mut s := clean_system()
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.nm_bus = 'can0'
	s.nodes[0].view.local_bus_fd = {
		'can0': true
	}
	assert errs(validate_system(s)).any(it.contains('fd = true')
		&& it.contains('classic-only')), errs(validate_system(s)).str()
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
') or { panic(err) }
	os.write_file(os.join_path(dir, 'system.toml'), '
[bus.compute]
interface = "can0"
[[node]]
name = "a"
ecu = "n.toml"
buses = ["compute"]
nm = 0x11
trace = 1
') or { panic(err) }
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
') or { panic(err) }
	view := load_node(os.join_path(dir, 'n.toml')) or { panic(err) }
	assert !view.has_telemetry, 'omitted [telemetry].enabled must default to false (loom2v parse_telemetry)'
}

// REQ-TOPO-005: a threadx node's comm thread owns only the telemetry bus, so a
// signal it produces/consumes on any other bus is not generatable.
fn test_threadx_signal_off_telemetry_bus_is_error() {
	mut s := clean_system()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[0].buses = ['compute', 'edge']
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.nm_bus = 'can0'
	s.nodes[0].view.local_buses = ['can0', 'can1']
	s.nodes[0].view.produces['can1'] = ['Extra'] // a signal off the telemetry bus
	assert errs(validate_system(s)).any(it.contains('on bus "can1"')
		&& it.contains('owns only the telemetry bus')), errs(validate_system(s)).str()
}

// REQ-TOPO-001: a threadx node whose telemetry interface is a local bus no system
// bus declares transmits telemetry on an undeclared channel — flagged even with
// no application signal on it.
fn test_undeclared_telemetry_interface_is_error() {
	mut s := clean_system()
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can9' // not a system bus interface
	s.nodes[0].view.nm_bus = 'can9'
	s.nodes[0].view.local_buses = ['can0', 'can9']
	assert errs(validate_system(s)).any(it.contains('[bus.can9]')
		&& it.contains('telemetry')), errs(validate_system(s)).str()
}

// --- codex #141 round-12 fixes ---

// REQ-TOPO-006: a system-level cross-bus route is not generated in P1 (loom2v
// emits no system routes), so its mere presence is an error — a clean verdict
// must not imply a forwarder exists.
fn test_system_route_not_generated_is_error() {
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
	assert errs(validate_system(s)).any(it.contains('not generated in P1')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: a telemetry id equal to ANOTHER node's alive id collides on the
// wire — checked against every active NM participant, not just the sender's range.
fn test_telemetry_id_aliases_other_node_alive() {
	mut s := clean_system()
	// node 0 has NO NM of its own but transmits telemetry at 0x513 = node 1's alive
	s.nodes[0].view.is_threadx = true
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
') or { panic(err) }
	os.write_file(os.join_path(dir, 'system.toml'), '
[bus.compute]
interface = "can0"
[[node]]
name = "a"
ecu = "n.toml"
buses = ["compute"]
nm = 0x11
trace = 1
') or { panic(err) }
	mut sys := parse_system(os.join_path(dir, 'system.toml')) or { panic(err) }
	load_errs := sys.load_nodes()
	assert !load_errs.any(it.contains('alive')), 'inactive NM named alive must not require a DBC: ${load_errs}'
}

// --- codex #141 round-13 fixes ---

// REQ-TOPO-005: loom2v panics for a threadx node with any [[isotp]] (ISO-TP is
// not generated on the comm thread yet).
fn test_threadx_isotp_is_error() {
	mut s := clean_system()
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.nm_bus = 'can0'
	s.nodes[0].view.has_isotp = true
	assert errs(validate_system(s)).any(it.contains('[[isotp]]')
		&& it.contains('does not generate ISO-TP')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: two nodes physically using the same ISO-TP diagnostic id collide
// on the wire even when their system.toml diag allocations differ.
fn test_isotp_id_collision_is_error() {
	mut s := clean_system()
	s.nodes[0].view.isotp_ids = [u32(0x700)]
	s.nodes[1].view.isotp_ids = [u32(0x700)] // same on-wire diag id
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
') or { panic(err) }
	mut s := System{
		dir:   dir
		buses: [Bus{
			name:      'compute'
			interface: 'can0'
			dbc:       'compute.dbc'
		}]
		nodes: [Node{
			name:  'a'
			buses: ['compute']
			view:  NodeView{
				is_threadx:        true
				has_telemetry:     true
				telem_bus:         'can0'
				trace_on:          true
				trace_record_name: 'trace_record' // snake of "TraceRecord" -> 0x120
				trace_rsp_id:      0x7e3
			}
		}]
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
') or { panic(err) }
	mut s := System{
		dir:   dir
		buses: [Bus{
			name:      'compute'
			interface: 'can0'
			dbc:       'compute.dbc'
		}]
		nodes: [
			Node{
				name:  'a'
				buses: ['compute']
				view:  NodeView{
					is_threadx:        true
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
	assert errs(validate_system(s)).any(it.contains('exceeds 0x7ff')
		&& it.contains('11-bit')), errs(validate_system(s)).str()
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

// REQ-TOPO-003: loom2v's threadx comm bridge only encodes a trivial u32 LE @ bit0
// signal — another DBC layout is not generatable.
fn test_threadx_nontrivial_signal_layout_is_error() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_layout_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// Speed is 16-bit -> not the trivial u32 layout
	os.write_file(os.join_path(dir, 'compute.dbc'), 'VERSION ""

BU_: a

BO_ 288 SpeedFrame: 8 a
 SG_ Speed : 0|16@1+ (1,0) [0|65535] "" a
') or { panic(err) }
	mut s := System{
		dir:   dir
		buses: [Bus{
			name:      'compute'
			interface: 'can0'
			dbc:       'compute.dbc'
		}]
		nodes: [Node{
			name:  'a'
			buses: ['compute']
			view:  NodeView{
				is_threadx:    true
				has_telemetry: true
				telem_bus:     'can0'
				produces:      {
					'can0': ['Speed']
				}
				local_buses: ['can0']
			}
		}]
	}
	assert errs(validate_system(s)).any(it.contains('Speed')
		&& it.contains('not a plain unsigned little-endian 32-bit')), errs(validate_system(s)).str()
}

// REQ-TOPO-002: shell.fc (default 0x7f2) is a reserved RX id — another node
// transmitting there is misrouted into g_sh.on_fc.
fn test_shell_fc_id_reserved() {
	mut s := clean_system()
	s.nodes[0].view.is_threadx = true
	s.nodes[0].view.has_telemetry = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.nm_bus = 'can0'
	s.nodes[0].view.telem_id = 0x7a0
	s.nodes[0].view.shell_on = true
	s.nodes[0].view.shell_out_id = 0x7f1
	s.nodes[0].view.shell_in_id = 0x7f0
	s.nodes[0].view.shell_fc_id = 0x7f2 // reserved rx
	s.nodes[1].view.is_threadx = true
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
') or { panic(err) }
	mut s := System{
		dir:   dir
		buses: [Bus{
			name:      'compute'
			interface: 'can0'
			dbc:       'compute.dbc'
		}]
		nodes: [Node{
			name:  'a'
			buses: ['compute']
			view:  NodeView{
				is_threadx:        true
				has_telemetry:     true
				telem_bus:         'can0'
				telem_id:          0x7a0
				trace_on:          true
				trace_record_name: 'NoSuchMessage' // not in the DBC
				trace_rsp_id:      0x7a1
			}
		}]
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
