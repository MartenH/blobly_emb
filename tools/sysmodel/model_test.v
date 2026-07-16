module sysmodel

import os

// @verifies REQ-TOPO-001, REQ-TOPO-002, REQ-TOPO-004, REQ-TOPO-005, REQ-TOPO-006

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
	return System{
		buses:   [Bus{
			name:           'compute'
			interface:      'can0'
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
					fb_writes:   ['Speed']
					fb_reads:    ['Rpm']
					local_buses: ['can0']
				}
			},
			Node{
				name:         'b'
				buses:        ['compute']
				nm:           0x13
				has_nm_alloc: true
				trace:        2
				view:         NodeView{
					fb_writes:   ['Rpm']
					fb_reads:    ['Speed']
					local_buses: ['can0']
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
