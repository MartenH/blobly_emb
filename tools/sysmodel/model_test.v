module sysmodel

import os

// @verifies REQ-TOPO-001, REQ-TOPO-002, REQ-TOPO-003, REQ-TOPO-004, REQ-TOPO-005, REQ-TOPO-006

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
				trace: 1
				view:  NodeView{
					produces:  {
						'can0': ['Speed']
					}
					consumes:  {
						'can0': ['Rpm']
					}
					has_nm:      true
					nm_node:     0x11
					has_nm_node: true
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
				trace: 2
				view:  NodeView{
					produces:  {
						'can0': ['Rpm']
					}
					consumes:  {
						'can0': ['Speed']
					}
					has_nm:      true
					nm_node:     0x13
					has_nm_node: true
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
		trace: 3
		view:  NodeView{
			consumes:    {
				'can1': ['Speed']
			}
			has_nm:      true
			nm_node:     0x20
			has_nm_node: true
			alive:       0x520
			has_alive:   true
			peers_lo:    0x500
			peers_hi:    0x53f
			local_buses: ['can1']
		}
	}
	// without a route -> error (no producer on edge)
	assert errs(validate_system(s)).any(it.contains('Speed') && it.contains('no node transmits'))
	// add the route -> the consumer is satisfied
	s.routes << Route{
		gateway: 'sysnode'
		signal:  'Speed'
		from:    'compute'
		to:      'edge'
	}
	assert !errs(validate_system(s)).any(it.contains('Speed') && it.contains('no node transmits')), 'route should satisfy the cross-bus consumer'
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
	s.nodes[1].view.nm_timeout_ms = 500 // both declared, differ
	issues := validate_system(s)
	assert errs(issues).any(it.contains('timeout_ms mismatch')), errs(issues).str()
	// a param only one node declares must NOT false-positive (default vs explicit)
	mut s2 := clean_system()
	s2.nodes[0].view.nm_repeat_ms = 200 // only one declares it
	assert !errs(validate_system(s2)).any(it.contains('repeat_ms mismatch')), 'one-sided default should not flag'
}

// REQ-TOPO-001: two nodes transmitting the SAME frame (different signals into
// one PDU) contend on the wire even though each signal has one writer.
fn test_frame_single_writer_is_error() {
	mut s := clean_system()
	s.nodes[0].view.tx_frames['can0'] = ['StatusFrame']
	s.nodes[1].view.tx_frames['can0'] = ['StatusFrame'] // both own the same frame
	issues := validate_system(s)
	assert errs(issues).any(it.contains('frame "StatusFrame"') && it.contains('one frame owner')), errs(issues).str()
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
		trace: 3
		view:  NodeView{
			consumes:    {
				'can1': ['Torque']
			}
			has_nm:      true
			nm_node:     0x20
			has_nm_node: true
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
	s.nodes << Node{
		name:  'third'
		buses: ['compute']
		nm:    0x15
		has_nm_alloc: true
		trace: 4
		view:  NodeView{
			has_nm:        true
			nm_node:       0x15
			has_nm_node:   true
			alive:         0x515
			has_alive:   true
			peers_lo:      0x500
			peers_hi:      0x53f
			local_buses:   ['can0']
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

// --- P1b dissolution model (validate_system_gen) ---

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
		buses:   [Bus{
			name:           'compute'
			interface:      'can0'
			dbc:            'compute.dbc'
			has_nm_cluster: true
			nm_peers_lo:    0x500
			nm_peers_hi:    0x53f
		}]
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
				}
			},
		]
	}
}

fn test_dissolved_clean() {
	issues := validate_system_gen(clean_dissolved())
	assert errs(issues).len == 0, 'clean dissolved system flagged: ${errs(issues)}'
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

// REQ-TOPO-005: the producer's FBs must actually write the signal.
fn test_dissolved_producer_doesnt_write() {
	mut s := clean_dissolved()
	s.nodes[0].view.fb_writes = [] // 'a' declared producer of Speed but writes nothing
	assert errs(validate_system_gen(s)).any(it.contains('has no FB that writes it'))
}

// REQ-TOPO-001: two signals in one DBC frame from different producers contend.
fn test_dissolved_frame_owner_collision() {
	mut s := clean_dissolved()
	s.signals[1].frame = 'SpeedFrame' // Rpm(prod b) shares SpeedFrame with Speed(prod a)
	assert errs(validate_system_gen(s)).any(it.contains('one frame owner per bus'))
}

// REQ-TOPO-001: a signal no other node reads is a warning, not an error.
fn test_dissolved_unread_signal_is_warning() {
	mut s := clean_dissolved()
	s.nodes[1].view.fb_reads = [] // nobody reads Speed anymore
	issues := validate_system_gen(s)
	assert errs(issues).len == 0
	assert issues.any(it.severity == .warning && it.msg.contains('Speed') && it.msg.contains('read by no other node'))
}

// --- P1b dissolution: codex #142 round-1 fixes ---

// REQ-TOPO-004: a node whose derived alive id (peers base + nm) falls outside
// the cluster range would be ignored by NM.
fn test_dissolved_alive_out_of_range() {
	mut s := clean_dissolved()
	s.nodes[0].nm = 0x40 // 0x500 + 0x40 = 0x540, outside [0x500,0x53f]
	assert errs(validate_system_gen(s)).any(it.contains('outside the cluster range'))
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

// REQ-TOPO-001: an FB reading a signal the system never declared.
fn test_dissolved_unknown_read_is_error() {
	mut s := clean_dissolved()
	s.nodes[0].view.fb_reads = ['Rpm', 'Ghost']
	assert errs(validate_system_gen(s)).any(it.contains('reads "Ghost"') && it.contains('does not declare'))
}

// REQ-TOPO-005: a node with no NM allocation (the generator always emits [nm]).
fn test_dissolved_node_without_nm_alloc() {
	mut s := clean_dissolved()
	s.nodes[0].has_nm_alloc = false
	assert errs(validate_system_gen(s)).any(it.contains('must allocate an `nm`'))
}

// REQ-TOPO-006: a multi-bus node (P1 wires one bus per node; gateways are P2).
fn test_dissolved_multibus_node_rejected() {
	mut s := clean_dissolved()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[0].buses = ['compute', 'edge']
	assert errs(validate_system_gen(s)).any(it.contains('wires exactly one bus per node'))
}

// REQ-TOPO-001: the producer writing a signal from two FBs (two publishers).
fn test_dissolved_two_writers_rejected() {
	mut s := clean_dissolved()
	s.nodes[0].view.fb_writes = ['Speed', 'Speed'] // two handlers write Speed
	assert errs(validate_system_gen(s)).any(it.contains('writes it from 2 FBs'))
}

// REQ-TOPO-001: a NON-producer node writing a declared signal.
fn test_dissolved_nonproducer_write_rejected() {
	mut s := clean_dissolved()
	s.nodes[1].view.fb_writes = ['Rpm', 'Speed'] // b writes Speed, but a is the producer
	assert errs(validate_system_gen(s)).any(it.contains('only the producer may write'))
}

// --- P1b dissolution: codex #142 round-2 fixes ---

// REQ-TOPO-001: a signal declared with no fields (loom2v rejects an empty map).
fn test_dissolved_signal_no_fields() {
	mut s := clean_dissolved()
	s.signals[0].fields = map[string]string{}
	assert errs(validate_system_gen(s)).any(it.contains('has no value field'))
}

// REQ-TOPO-005: a partial node that authors bus wiring (bypasses the checks).
fn test_dissolved_partial_authors_wiring() {
	mut s := clean_dissolved()
	s.nodes[0].view.local_buses = ['can0'] // authored a [bus.can0]
	assert errs(validate_system_gen(s)).any(it.contains('authors bus wiring'))
}

// REQ-TOPO-001: a node whose bus is not declared in system.toml.
fn test_dissolved_undeclared_bus() {
	mut s := clean_dissolved()
	s.nodes[0].buses = ['ghostbus']
	s.signals[0].bus = 'ghostbus' // so membership passes textually
	assert errs(validate_system_gen(s)).any(it.contains('bus "ghostbus" is not declared'))
}

// REQ-TOPO-002: an NM node id above 0xff (loom2v requires 0..255).
fn test_dissolved_nm_over_255() {
	mut s := clean_dissolved()
	s.buses[0].nm_peers_hi = 0x6ff // widen so the alive check doesn't mask this
	s.nodes[0].nm = 0x100
	assert errs(validate_system_gen(s)).any(it.contains('exceeds 0xff'))
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
	assert errs(validate_system_gen(s)).any(it.contains('disagree on cycle') && it.contains('effective'))
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

// REQ-TOPO-005: a partial authoring a bus-endpoint [[signal]] with NO [bus.*].
fn test_dissolved_partial_signal_without_bus_table() {
	mut s := clean_dissolved()
	s.nodes[0].view.authored_signals = true // authored a [[signal]] (no [bus])
	assert errs(validate_system_gen(s)).any(it.contains('authors bus wiring') && it.contains('[[signal]]'))
}

// REQ-TOPO-001: a consumer that reads a signal but isn't on its bus.
fn test_dissolved_consumer_off_bus() {
	mut s := clean_dissolved()
	s.buses << Bus{
		name:      'edge'
		interface: 'can1'
	}
	s.nodes[1].buses = ['edge'] // b reads Speed (on compute) but sits on edge
	assert errs(validate_system_gen(s)).any(it.contains('consumer "b"') && it.contains('not on its bus'))
}

// --- P1b-2 DBC conformance (REQ-TOPO-003) ---

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

fn test_dbc_conformance_clean() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_ok_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	s := dissolved_with_dbc(dir, good_dbc)
	issues := check_dbc_conformance(s)
	assert errs(issues).len == 0, 'clean DBC flagged: ${errs(issues)}'
}

// REQ-TOPO-003: a signal whose frame is not defined in the bus DBC.
fn test_dbc_frame_missing() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_dbc_miss_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	// DBC has only SpeedFrame; RpmFrame is absent
	s := dissolved_with_dbc(dir, 'VERSION ""\nBU_: a b\nBO_ 288 SpeedFrame: 8 a\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" b\n')
	assert errs(check_dbc_conformance(s)).any(it.contains('frame "RpmFrame" is not defined'))
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
	assert errs(check_dbc_conformance(s)).any(it.contains('transmitted by "b"') && it.contains('producer "a"'))
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

// --- P1b dissolution: codex #142 round-4 fixes ---

// REQ-TOPO-001: a cross-node signal must carry EXACTLY ONE field (loom2v's
// bridge serializes only the first value field per DBC signal).
fn test_dissolved_multifield_signal() {
	mut s := clean_dissolved()
	s.signals[0].fields = {
		'kph': 'u16'
		'mph': 'u16'
	}
	assert errs(validate_system_gen(s)).any(it.contains('value fields') && it.contains('carries exactly one'))
}

// REQ-TOPO-001: a signal field must be a fixed scalar type (no heap types).
fn test_dissolved_non_scalar_field() {
	mut s := clean_dissolved()
	s.signals[0].fields = {
		'kph': 'string'
	}
	assert errs(validate_system_gen(s)).any(it.contains('unsupported type "string"'))
}

// REQ-TOPO-003: a bus carrying cross-node signals must declare a DBC.
fn test_dissolved_bus_without_dbc() {
	mut s := clean_dissolved()
	s.buses[0].dbc = '' // no DBC, but it carries Speed/Rpm
	assert errs(check_dbc_conformance(s)).any(it.contains('carries cross-node signals but declares no `dbc`'))
}

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

// --- P1b dissolution: codex #142 round-5 fixes ---

// REQ-TOPO-001: a 64-bit integer field is lossy through loom2v's f64 bridge.
fn test_dissolved_u64_field_rejected() {
	mut s := clean_dissolved()
	s.signals[0].fields = {
		'big': 'u64'
	}
	assert errs(validate_system_gen(s)).any(it.contains('64-bit integers are lossy'))
}

// REQ-TOPO-001: a lone `valid` field has no value for the bridge to serialize.
fn test_dissolved_sole_valid_field_rejected() {
	mut s := clean_dissolved()
	s.signals[0].fields = {
		'valid': 'bool'
	}
	assert errs(validate_system_gen(s)).any(it.contains('has no value field'))
}

// REQ-TOPO-001: a producer that also reads its own bus-published signal.
fn test_dissolved_producer_reads_own_signal() {
	mut s := clean_dissolved()
	s.nodes[0].view.fb_reads = ['Rpm', 'Speed'] // a produces Speed AND reads it
	assert errs(validate_system_gen(s)).any(it.contains('also reads it'))
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
	assert errs(check_dbc_conformance(s)).any(it.contains('field is unsigned but DBC SG_') && it.contains('signed'))
}

// --- P1b dissolution: codex #142 round-6 fixes ---

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

// REQ-TOPO-001: a cross-node RX signal read from two partitions (SPSC violation).
fn test_dissolved_cross_partition_reader() {
	mut s := clean_dissolved()
	// domain (b) reads Speed from two partitions
	s.nodes[1].view.read_partitions = {
		'Speed': ['ctlA', 'ctlB']
	}
	assert errs(validate_system_gen(s)).any(it.contains('read from 2 partitions'))
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

// --- P1b dissolution: codex #142 round-7 fix ---

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

// --- P1b dissolution: codex #142 (missed @08:17) fixes ---

// REQ-TOPO-004: a host (non-threadx) node on an NM cluster gets a dead [nm].
fn test_dissolved_host_node_nm_dead() {
	mut s := clean_dissolved()
	s.nodes[0].view.is_threadx = false // a host node
	assert errs(validate_system_gen(s)).any(it.contains('not a threadx target') && it.contains('no runtime'))
}

// REQ-TOPO-004: NM ids above 0x7ff are truncated by the 11-bit FDCAN backend.
fn test_dissolved_nm_id_over_11bit() {
	mut s := clean_dissolved()
	s.buses[0].nm_peers_lo = 0x800
	s.buses[0].nm_peers_hi = 0x83f // range above 11-bit
	assert errs(validate_system_gen(s)).any(it.contains('exceeds 0x7ff'))
}

// REQ-TOPO-005: a [[route]] authored in a partial is uncheckable wiring.
fn test_dissolved_partial_authors_route() {
	mut s := clean_dissolved()
	s.nodes[0].view.authored_routes = true
	assert errs(validate_system_gen(s)).any(it.contains('authors bus wiring') && it.contains('[[route]]'))
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
