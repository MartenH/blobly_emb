module sysmodel

import os

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
				trace: 1
				view:  NodeView{
					produces:  {
						'can0': ['Speed']
					}
					consumes:  {
						'can0': ['Rpm']
					}
					has_nm:   true
					nm_node:  0x11
					alive:    0x511
					peers_lo: 0x500
					peers_hi: 0x53f
				}
			},
			Node{
				name:  'domain'
				buses: ['compute']
				nm:    0x13
				trace: 2
				view:  NodeView{
					produces:  {
						'can0': ['Rpm']
					}
					consumes:  {
						'can0': ['Speed']
					}
					has_nm:   true
					nm_node:  0x13
					alive:    0x513
					peers_lo: 0x500
					peers_hi: 0x53f
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
	// zone consumes Speed on edge; only sysnode produces it on compute
	s.nodes << Node{
		name:  'zone'
		buses: ['edge']
		nm:    0x20
		trace: 3
		view:  NodeView{
			consumes: {
				'can1': ['Speed']
			}
			has_nm:   true
			peers_lo: 0x500
			peers_hi: 0x53f
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
