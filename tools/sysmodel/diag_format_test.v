module sysmodel

import os
import toml

// A diagnostic id is its number AND its format: a system node's diag allocation stated one way
// (req / rsp, 11- or 29-bit, or normal fixed addressing's sa / ta), its uniqueness and its
// collisions with the other frames on its bus judged by (id, format), a node's own [isotp] held to
// it, and a gateway's route carrying it.
// @verifies REQ-TOPO-002 REQ-TOPO-013 REQ-TOPO-014 REQ-NET-021

fn errors_of(issues []Issue) []string {
	return issues.filter(it.severity == .error).map(it.msg)
}

// parsed: a one-bus system whose node "n" carries `diag`, parsed as syscheck parses it
fn parsed(diag string) System {
	dir := os.join_path(os.temp_dir(), 'sysmodel_diag_fmt_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'system.toml')
	os.write_file(path, '[bus.compute]\ninterface = "can0"\n\n[[node]]\nname  = "n"\necu   = "n.toml"\nbuses = ["compute"]\ndiag  = ${diag}\n') or {
		panic(err)
	}
	return parse_system(path) or { panic(err) }
}

fn test_a_diag_on_normal_fixed_addressing_derives_its_ids() {
	d := parsed('{ addressing = "normal_fixed", sa = 0x10, ta = 0xF1, functional_ta = 0x33 }').nodes[0].diag
	assert d.errs == []
	assert d.req == 0x18DA10F1 && d.rsp == 0x18DAF110 && d.functional == 0x18DB33F1
	assert d.ext && d.fixed
	e := parsed('{ req = 0x18DA10F1, rsp = 0x18DAF110, ext = true }').nodes[0].diag
	assert e.errs == [] && e.ext && !e.fixed && e.req == 0x18DA10F1
	s := parsed('{ req = 0x7A0, rsp = 0x7A8 }').nodes[0].diag
	assert s.errs == [] && !s.ext && s.req == 0x7A0
}

fn test_a_diag_stated_wrongly_is_refused_by_both_models() {
	for diag, want in {
		'{ req = "0x7A0", rsp = 0x7A8 }':                                 'node "n" diag req must be an integer'
		'{ req = 0x800, rsp = 0x7A8 }':                                   'node "n" diag req 0x800 must be a standard 11-bit id'
		'{ addressing = "normal_fixed", sa = 0x10, ta = 0xF1, req = 1 }': 'req is given with addressing = "normal_fixed"'
		'{ addressing = "normal_fixed", ta = 0xF1 }':                     'needs sa'
		'{ addressing = "normal_fixed", sa = 256, ta = 0xF1 }':           'sa = 0x100 is out of range'
		'{ addressing = "mixed", req = 0x7A0, rsp = 0x7A8 }':             'addressing "mixed" is not one of'
	} {
		s := parsed(diag)
		for issues in [validate_system(s), validate_system_gen(s)] {
			hit := issues.filter(it.severity == .error && it.msg.contains(want))
			assert hit.len == 1, '${diag}: ${errors_of(issues)}'
			assert hit[0].req == 'REQ-TOPO-013'
		}
	}
}

fn diag_node(name string, d Diag) Node {
	return Node{
		name:  name
		buses: ['compute']
		diag:  d
	}
}

fn two_diags(a Diag, b Diag) System {
	return System{
		buses: [Bus{
			name:      'compute'
			interface: 'can0'
			kind:      'can'
		}]
		nodes: [diag_node('a', a), diag_node('b', b)]
	}
}

fn collisions(s System) []string {
	mut out := errors_of(validate_system(s)).filter(it.contains('collides'))
	out << errors_of(validate_system_gen(s)).filter(it.contains('collides'))
	return out
}

// REQ-TOPO-002: an 11-bit and a 29-bit id of one number are two ids; two 29-bit ones are one
fn test_diagnostic_ids_are_unique_by_number_and_format() {
	std := Diag{
		req: 0x7A0
		rsp: 0x7A8
	}
	ext := Diag{
		req: 0x7A0
		rsp: 0x7A8
		ext: true
	}
	assert collisions(two_diags(std, ext)) == []
	c := collisions(two_diags(ext, ext))
	assert c.any(it.contains('diagnostic request id 0x7a0 (29-bit) (node "b") collides')), c.str()
	// a node's 29-bit [isotp] id on another node's 11-bit diag number is no collision either
	mut s := two_diags(std, ext)
	s.nodes[1].view.isotp_conns = [IsotpConn{
		iface: 'can0'
		rx_id: 0x7A0
		tx_id: 0x7A8
		ext:   true
	}]
	assert collisions(s) == []
	s.nodes[1].view.isotp_conns[0].ext = false // ... and on its 11-bit number, one
	assert collisions(s).any(it.contains('[isotp] diagnostic id 0x7a0 collides')), collisions(s).str()
}

fn served(d Diag, c IsotpConn) []Issue {
	mut s := two_diags(d, Diag{})
	s.nodes[0].view.isotp_conns = [c]
	mut issues := validate_system(s)
	issues << validate_system_gen(s)
	return issues.filter(it.req == 'REQ-TOPO-014')
}

// REQ-TOPO-014: a node serves on its allocation — request, response, format and (where the
// allocation states one) functional id; a node with only one side is not judged
fn test_a_node_serves_on_its_diagnostic_allocation() {
	alloc := Diag{
		req: 0x7A0
		rsp: 0x7A8
	}
	conn := IsotpConn{
		iface: 'can0'
		rx_id: 0x7A0
		tx_id: 0x7A8
	}
	assert served(alloc, conn) == []
	off := served(alloc, IsotpConn{ ...conn, rx_id: 0x7A1 })
	assert off.len == 2 // once per model
	assert off[0].msg == 'node "a": its [isotp] listens on 0x7a1 and answers on 0x7a8, but its diag allocation is 0x7a0 / 0x7a8 — a node serves on its diagnostic allocation'
	wide := served(Diag{ ...alloc, ext: true }, conn)
	assert wide.len == 2 && wide[0].msg.contains('its diag allocation is 0x7a0 (29-bit) / 0x7a8 (29-bit)'), wide.str()
	fixed := Diag{
		req:        0x18DA10F1
		rsp:        0x18DAF110
		ext:        true
		fixed:      true
		functional: 0x18DB33F1
	}
	conn29 := IsotpConn{
		iface:         'can0'
		rx_id:         0x18DA10F1
		tx_id:         0x18DAF110
		functional_id: 0x18DB33F1
		ext:           true
	}
	assert served(fixed, conn29) == [] // a normal-addressing [isotp] on the derived ids serves it
	func := served(fixed, IsotpConn{ ...conn29, functional_id: 0x7DF })
	assert func.len == 2 && func[0].msg.contains('its [isotp] functional id is 0x7df (29-bit), but its diag functional_ta makes it 0x18db33f1 (29-bit)'), func.str()
	none_ := served(fixed, IsotpConn{ ...conn29, functional_id: 0 })
	assert none_.len == 2 && none_[0].msg.contains('functional id is none'), none_.str()
	// one side only: nothing to compare
	assert served(Diag{}, conn) == []
	only := two_diags(alloc, Diag{})
	assert errors_of(validate_system(only)).filter(it.contains('serves on')) == []
}

// a gateway's route compares the same way, and a routed node's difference is said once, by the
// route check, with the route's consequence (check_diag_conn leaves a routed node to it)
fn test_a_routed_nodes_difference_is_said_once() {
	mut s := System{
		buses: [Bus{
			name:      'compute'
			interface: 'can0'
			kind:      'can'
		}, Bus{
			name:      'edge'
			interface: 'can1'
			kind:      'can'
		}]
		nodes: [
			Node{
				name:        'gw'
				buses:       ['compute', 'edge']
				has_doip:    true
				doip_routes: ['zone']
			},
			Node{
				name:  'zone'
				buses: ['edge']
				diag:  Diag{
					req:         0x18DA20F1
					rsp:         0x18DAF120
					ext:         true
					logical:     0x07C0
					logical_raw: 0x07C0
					has_logical: true
				}
				view:  NodeView{
					isotp_conns: [IsotpConn{
						iface: 'can0'
						rx_id: 0x18DA20F1
						tx_id: 0x18DAF120
					}]
				}
			},
		]
	}
	said := errors_of(validate_system_gen(s)).filter(it.contains('its [isotp] listens on'))
	assert said.len == 1, said.str()
	assert said[0].contains('node "gw": doip route to "zone"')
		&& said[0].contains('but its diag allocation is 0x18da20f1 (29-bit) / 0x18daf120 (29-bit)')
		&& said[0].ends_with('— the gateway forwards to the allocation'), said[0]
	s.nodes[1].view.isotp_conns[0].ext = true
	assert errors_of(validate_system_gen(s)).filter(it.contains('its [isotp] listens on')) == []
	// its functional id is its own listener's, never the route's (the router forwards physical
	// requests only): said by REQ-TOPO-014, without the route's consequence
	s.nodes[1].diag.functional = 0x18DB33F1
	func := validate_system_gen(s).filter(it.severity == .error && it.msg.contains('functional id'))
	assert func.len == 1, func.str()
	assert func[0].req == 'REQ-TOPO-014'
	assert func[0].msg == 'node "zone": its [isotp] functional id is none, but its diag functional_ta makes it 0x18db33f1 (29-bit) — a node serves on its diagnostic allocation', func[0].msg
	s.nodes[1].view.isotp_conns[0].functional_id = 0x18DB33F1
	assert errors_of(validate_system_gen(s)).filter(it.contains('functional id')) == []
}

const fmt_dbc = 'VERSION ""

BU_: A B

BO_ 2564485392 ExtAlias: 8 B
 SG_ ExtSig : 0|8@1+ (1,0) [0|255] "" A

BO_ 2016 Std7E0: 8 B
 SG_ StdSig : 0|8@1+ (1,0) [0|255] "" A

BO_ 1968 Std7B0: 8 B
 SG_ Std7B0Sig : 0|8@1+ (1,0) [0|255] "" A

BO_ 2564502514 FuncAlias: 8 B
 SG_ FuncSig : 0|8@1+ (1,0) [0|255] "" A
'

// framed: two nodes on `compute`, whose DBC (fmt_dbc) has extended frames 0x18DAF110 and
// 0x18DB33F2 and standard frames 0x7E0 and 0x7B0; node "b" produces `produced`
fn framed(dir string, a Node, produced string) System {
	os.mkdir_all(dir) or { panic(err) }
	os.write_file(os.join_path(dir, 'bus.dbc'), fmt_dbc) or { panic(err) }
	mut b := Node{
		name:  'b'
		buses: ['compute']
	}
	if produced != '' {
		b.view.produces['can0'] = [produced]
	}
	return System{
		dir:   dir
		buses: [Bus{
			name:      'compute'
			interface: 'can0'
			kind:      'can'
			dbc:       'bus.dbc'
		}]
		nodes: [a, b]
	}
}

fn frame_errs(s System) []string {
	return errors_of(check_telemetry_frames(s))
}

// REQ-TOPO-002 on the bus: a 29-bit diagnostic id is sent whole (never "exceeds 0x7ff"), never
// meets the 11-bit module frames, and meets a DBC frame only when that one is extended too
fn test_a_29_bit_connection_is_held_to_the_frames_on_its_bus_in_its_format() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_diag_frames_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	a := Node{
		name:  'a'
		buses: ['compute']
		view:  NodeView{
			isotp_conns: [IsotpConn{
				iface: 'can0'
				rx_id: 0x18DA10F1
				tx_id: 0x18DAF111
				ext:   true
			}]
		}
	}
	assert frame_errs(framed(dir, a, '')) == []
	// its tx on the number of another node's 11-bit telemetry frame: another frame
	mut tel := framed(dir, Node{
		...a
		view: NodeView{
			isotp_conns: [IsotpConn{
				iface: 'can0'
				rx_id: 0x18DA10F1
				tx_id: 0x7E1
				ext:   true
			}]
		}
	}, '')
	tel.nodes[1].view.has_telemetry = true
	tel.nodes[1].view.telem_bus = 'can0'
	tel.nodes[1].view.telem_id = 0x7E1
	assert frame_errs(tel) == []
	// on the extended DBC frame of its number: one frame, refused
	mut on := framed(dir, Node{
		...a
		view: NodeView{
			isotp_conns: [IsotpConn{
				iface: 'can0'
				rx_id: 0x18DA10F1
				tx_id: 0x18DAF110
				ext:   true
			}]
		}
	}, 'ExtSig')
	e := frame_errs(on)
	assert e.any(it.contains('isotp tx id 0x18daf110 (29-bit) aliases DBC application frame "ExtAlias"')), e.str()
	assert e.len == 1, e.str() // said once, as the DBC frame it is — not again as b's production
}

// REQ-TOPO-002: a node whose ecu.toml has no [isotp] is held to the frames on its diagnostic bus
// by its diag allocation — in the allocation's format; one on several CAN buses cannot be placed
fn test_a_diag_only_nodes_ids_are_held_to_the_frames_on_its_bus() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_diag_only_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	std := Node{
		name:  'a'
		buses: ['compute']
		diag:  Diag{
			req: 0x7A0
			rsp: 0x7B0
		}
	}
	e := frame_errs(framed(dir, std, ''))
	assert e.any(it.contains('diag rsp id 0x7b0 aliases DBC application frame "Std7B0"')), e.str()
	ext := Node{
		...std
		diag: Diag{
			req: 0x7A0
			rsp: 0x7B0
			ext: true
		}
	}
	assert frame_errs(framed(dir, ext, '')) == []
	// its request id held to every DBC frame on its bus, in its format — whoever sends it, a node
	// of the system or not (here nobody the system builds produces Std7E0), and said once when
	// another node produces it
	on_req := Node{
		...std
		diag: Diag{
			req: 0x7E0
			rsp: 0x7A8
		}
	}
	for produced in ['', 'StdSig'] {
		r := frame_errs(framed(dir, on_req, produced))
		assert r == ['node "a": diag req (rx) id 0x7e0 is DBC application frame "Std7E0" on bus "compute" — its payloads would reach the diagnostic server as requests'], r.str()
	}
	assert frame_errs(framed(dir, Node{ ...on_req, diag: Diag{ ...on_req.diag, ext: true } }, 'StdSig')) == []
	// on two CAN buses with no [isotp]: its diagnostic bus cannot be told, nothing is placed
	mut two := framed(dir, std, '')
	two.buses << Bus{
		name:      'edge'
		interface: 'can1'
		kind:      'can'
	}
	two.nodes[0].buses << 'edge'
	assert frame_errs(two) == []
}

// REQ-NET-021: an authored route serves its node only in the node's format
fn test_an_authored_route_serves_in_its_nodes_format() {
	mk := fn (route_ext bool, conn_ext bool) []string {
		s := System{
			buses: [Bus{
				name:      'compute'
				interface: 'can0'
				kind:      'can'
			}, Bus{
				name:      'edge'
				interface: 'can1'
				kind:      'can'
			}]
			nodes: [
				Node{
					name:  'gw'
					buses: ['compute', 'edge']
					view:  NodeView{
						doip_routes: [
							AuthoredRoute{
								node:  'zone'
								bus:   'can1'
								tx_id: 0x18DA20F1
								rx_id: 0x18DAF120
								ext:   route_ext
							},
						]
					}
				},
				Node{
					name:  'zone'
					buses: ['edge']
					view:  NodeView{
						isotp_conns: [IsotpConn{
							iface: 'can0'
							rx_id: 0x18DA20F1
							tx_id: 0x18DAF120
							ext:   conn_ext
						}]
					}
				},
			]
		}
		return errors_of(check_route_ids(s)).filter(it.contains('in that format'))
	}
	assert mk(true, true) == []
	e := mk(false, true)
	assert e.len == 1 && e[0].contains('sends on 0x18da20f1 and listens on 0x18daf120 on bus "edge"'), e.str()
	assert mk(true, false).len == 1
}

// REQ-TOPO-002: a diag-only node's functional id (normal fixed addressing's functional_ta) is
// reserved on its bus as a connection's functional id is — one rule for both kinds of node
fn test_a_diag_only_nodes_functional_id_is_reserved_on_its_bus() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_diag_func_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	d := Diag{
		req:        0x18DA10F2
		rsp:        0x18DAF210
		ext:        true
		fixed:      true
		functional: 0x18DB33F2
	}
	only := Node{
		name:  'a'
		buses: ['compute']
		diag:  d
	}
	e := frame_errs(framed(dir, only, 'FuncSig'))
	assert e == ['node "a": diag functional (rx) id 0x18db33f2 (29-bit) is DBC application frame "FuncAlias" on bus "compute" — its payloads would reach the diagnostic server as requests'], e.str()
	// without a functional id stated, nothing of its is on 0x18DB33F2
	assert frame_errs(framed(dir, Node{ ...only, diag: Diag{ ...d, functional: 0 } }, 'FuncSig')) == []
	// a node whose [isotp] states the same functional id is refused alike
	conn := Node{
		name:  'a'
		buses: ['compute']
		view:  NodeView{
			isotp_conns: [IsotpConn{
				iface:         'can0'
				rx_id:         0x18DA10F2
				tx_id:         0x18DAF210
				functional_id: 0x18DB33F2
				ext:           true
			}]
		}
	}
	c := frame_errs(framed(dir, conn, 'FuncSig'))
	assert c == ['node "a": isotp functional (rx) id 0x18db33f2 (29-bit) is DBC application frame "FuncAlias" on bus "compute" — its payloads would reach the diagnostic server as requests'], c.str()
}

// REQ-TOPO-002 in a DISSOLVED system: a node's signals are declared in system.toml, not in its
// partial, so what it transmits is read from there too — a production declared once at system
// scope meets the reservations on its bus as an authored [[signal]] does
fn test_a_dissolved_nodes_productions_are_its_frames() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_diag_dissolved_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut s := framed(dir, Node{
		name:  'a'
		buses: ['compute']
	}, '')
	s.signals = [
		SysSignal{
			name:     'StdSig'
			producer: 'b'
			bus:      'compute'
			frame:    'Std7E0'
		},
		SysSignal{
			name:     'ExtSig'
			producer: 'b'
			bus:      'compute'
			frame:    'ExtAlias'
		},
		SysSignal{
			name:     'Std7B0Sig'
			producer: 'a'
			bus:      'compute'
			frame:    'Std7B0'
		},
	]
	dbs := bus_dbcs(s)
	b := produced_frames(s, s.nodes[1], dbs).map('${it.bus}:${it.msg.name}')
	assert b == ['compute:Std7E0', 'compute:ExtAlias'], b.str()
	// an authored [[signal]] in the same frame is that frame once
	mut both := s.nodes[1]
	both.view.produces = {
		'can0': ['StdSig'] // a map of its own: a copied struct shares its map
	}
	assert produced_frames(s, both, dbs).len == 2
	assert produced_frames(s, s.nodes[0], dbs).map(it.msg.name) == ['Std7B0']
	// a node's module receive id on the frame another node produces through system.toml: refused
	// (a reservation held to the frames transmitted there, as for an authored production)
	s.nodes[0].view.comm_thread_on = true
	s.nodes[0].view.shell_on = true
	s.nodes[0].view.telem_bus = 'can0'
	s.nodes[0].view.shell_in_id = 0x7E0
	s.nodes[0].view.shell_fc_id = 0x7E2
	s.nodes[0].view.shell_out_id = 0x7E3
	e := frame_errs(s)
	assert e == ['bus "compute": application frame "Std7E0" 0x7e0 produced by "b" collides with shell in (rx) id of "a" — application traffic would be misrouted into that module / contend for the id'], e.str()
	s.signals = s.signals.filter(it.frame != 'Std7E0')
	assert frame_errs(s) == []
}

// REQ-TOPO-002: a frame of a node on ONE bus is placed on that bus, which its config calls can0
// whatever the system calls it — never on the system bus whose interface is can0
fn test_a_single_bus_nodes_diagnostic_frames_are_on_its_own_bus() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_diag_local_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	os.mkdir_all(dir) or { panic(err) }
	os.write_file(os.join_path(dir, 'bus.dbc'), fmt_dbc) or { panic(err) }
	os.write_file(os.join_path(dir, 'empty.dbc'), 'VERSION ""\n\nBU_: A B\n') or { panic(err) }
	// node "zone" sits on edge (can1) alone, and its [isotp] says can0: edge, not compute
	mk := fn [dir] (compute_dbc string, edge_dbc string) System {
		return System{
			dir:   dir
			buses: [Bus{
				name:      'compute'
				interface: 'can0'
				kind:      'can'
				dbc:       compute_dbc
			}, Bus{
				name:      'edge'
				interface: 'can1'
				kind:      'can'
				dbc:       edge_dbc
			}]
			nodes: [
				Node{
					name:  'zone'
					buses: ['edge']
					view:  NodeView{
						isotp_conns: [IsotpConn{
							iface: 'can0'
							rx_id: 0x18DB33F2
							tx_id: 0x18DAF2C0
							ext:   true
						}]
					}
				},
			]
		}
	}
	on_edge := frame_errs(mk('empty.dbc', 'bus.dbc'))
	assert on_edge.len == 1 && on_edge[0].contains('isotp rx (rx) id 0x18db33f2 (29-bit) is DBC application frame "FuncAlias" on bus "edge"'), on_edge.str()
	assert frame_errs(mk('bus.dbc', 'empty.dbc')) == []
}

// route_on_edge: gateway "gw" (compute + edge) with one authored [[doip.route]] to "zone" on edge,
// whose DBC is fmt_dbc (extended 0x18DAF110, standard 0x7E0); zone's [isotp] serves on the route's
// ids in the route's format; `others` sit on edge beside it
fn route_on_edge(dir string, tx u32, rx u32, ext bool, others []Node) System {
	os.mkdir_all(dir) or { panic(err) }
	os.write_file(os.join_path(dir, 'edge.dbc'), fmt_dbc) or { panic(err) }
	mut nodes := [
		Node{
			name:  'gw'
			buses: ['compute', 'edge']
			view:  NodeView{
				doip_routes: [
					AuthoredRoute{
						node:  'zone'
						bus:   'can1'
						tx_id: tx
						rx_id: rx
						ext:   ext
					},
				]
			}
		},
		Node{
			name:  'zone'
			buses: ['edge']
			view:  NodeView{
				isotp_conns: [IsotpConn{
					iface: 'can0'
					rx_id: tx
					tx_id: rx
					ext:   ext
				}]
			}
		},
	]
	nodes << others
	return System{
		dir:   dir
		buses: [Bus{
			name:      'compute'
			interface: 'can0'
			kind:      'can'
		}, Bus{
			name:      'edge'
			interface: 'can1'
			kind:      'can'
			dbc:       'edge.dbc'
		}]
		nodes: nodes
	}
}

fn route_errs(s System) []string {
	return errors_of(check_route_ids(s))
}

// REQ-NET-021 / REQ-NET-019: a route's request id meets the other frames on its bus by (id,
// format) — the bus DBC's frame that IS that id (never a J1939 PGN twin: every 0x18DA.... id shares
// PGN 0xDA00), and the other nodes' receive ids, a diag-only node's allocation included
fn test_a_routes_request_id_meets_the_frames_on_its_bus_in_its_format() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_route_fmt_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	// 0x18DA20F1 shares PGN 0xDA00 with the DBC's 0x18DAF110: a different frame, no collision
	assert route_errs(route_on_edge(dir, 0x18DA20F1, 0x18DAF120, true, [])) == []
	// the DBC frame that is its id, in its format: refused
	same := route_errs(route_on_edge(dir, 0x18DAF110, 0x18DA10F1, true, []))
	assert same.any(it.contains('sends its requests on 0x18daf110 (29-bit) on bus "edge", which is DBC application frame "ExtAlias"')), same.str()
	// the 11-bit DBC frame 0x7E0 is another frame to a 29-bit route on 0x7E0, the same to an 11-bit one
	assert route_errs(route_on_edge(dir, 0x7E0, 0x7E8, true, [])) == []
	std := route_errs(route_on_edge(dir, 0x7E0, 0x7E8, false, []))
	assert std.any(it.contains('sends its requests on 0x7e0 on bus "edge", which is DBC application frame "Std7E0"')), std.str()
	// another node's 11-bit [isotp] receive id: met only by an 11-bit route on its number
	other := Node{
		name:  'other'
		buses: ['edge']
		view:  NodeView{
			isotp_conns: [IsotpConn{
				iface: 'can0'
				rx_id: 0x7A0
				tx_id: 0x7A8
			}]
		}
	}
	assert route_errs(route_on_edge(dir, 0x7A0, 0x7A9, true, [other])) == []
	taken := route_errs(route_on_edge(dir, 0x7A0, 0x7A9, false, [other]))
	assert taken.any(it.contains('which is also the isotp rx (rx) id of "other"')), taken.str()
	// ... and a diag-only node's request and functional ids, in their format
	diag_only := Node{
		name:  'other'
		buses: ['edge']
		diag:  Diag{
			req:        0x18DA30F1
			rsp:        0x18DAF130
			ext:        true
			fixed:      true
			functional: 0x18DB33F1
		}
	}
	assert route_errs(route_on_edge(dir, 0x18DA20F1, 0x18DAF120, true, [diag_only])) == []
	req := route_errs(route_on_edge(dir, 0x18DA30F1, 0x18DAF120, true, [diag_only]))
	assert req.any(it.contains('which is also the diag req (rx) id of "other"')), req.str()
	func := route_errs(route_on_edge(dir, 0x18DB33F1, 0x18DAF120, true, [diag_only]))
	assert func.any(it.contains('which is also the diag functional (rx) id of "other"')), func.str()
	assert route_errs(route_on_edge(dir, 0x18DB33F1, 0x18DAF120, false, [diag_only])).all(!it.contains('"other"'))
}

// REQ-NET-021 / REQ-NET-019: a route system.toml declares (a gateway's doip.routes, which sysgen
// lowers into its [[doip.route]]) sends its node's requests in the node's diag format, and meets
// the other frames on the bus in it — the DBC frame that IS its request id, and another node's
// receive id, each only in that format
fn test_a_system_routes_format_is_its_nodes() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_sysroute_fmt_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'edge.dbc'), fmt_dbc) or { panic(err) }
	// gateway "gw" on compute and edge routes (system.toml) to "zone", alone on edge
	mk := fn [dir] (zone Diag, others []Node) []string {
		mut nodes := [
			Node{
				name:        'gw'
				buses:       ['compute', 'edge']
				doip_routes: ['zone']
			},
			Node{
				name:  'zone'
				buses: ['edge']
				diag:  zone
			},
		]
		nodes << others
		return route_errs(System{
			dir:   dir
			buses: [Bus{
				name:      'compute'
				interface: 'can0'
				kind:      'can'
			}, Bus{
				name:      'edge'
				interface: 'can1'
				kind:      'can'
				dbc:       'edge.dbc'
			}]
			nodes: nodes
		})
	}
	// normal fixed addressing, request id 0x18DAF110 (sa 0xF1, ta 0x10): the DBC's extended frame
	fixed := Diag{
		req:   0x18DAF110
		rsp:   0x18DA10F1
		ext:   true
		fixed: true
		sa:    0xF1
		ta:    0x10
	}
	e := mk(fixed, [])
	assert e == ['node "gw": doip route to "zone" sends its requests on 0x18daf110 (29-bit) on bus "edge", which is DBC application frame "ExtAlias" there — two transmitters of one id, and its payloads would reach "zone" as requests'], e.str()
	// a 29-bit route on 0x7E0 is not the DBC's 11-bit frame 0x7E0; an 11-bit one is
	assert mk(Diag{ req: 0x7E0, rsp: 0x7E8, ext: true }, []) == []
	std := mk(Diag{ req: 0x7E0, rsp: 0x7E8 }, [])
	assert std.len == 1 && std[0].contains('sends its requests on 0x7e0 on bus "edge", which is DBC application frame "Std7E0"'), std.str()
	// another node's receive id: met in its format only
	other := fn (ext bool) Node {
		return Node{
			name:  'other'
			buses: ['edge']
			view:  NodeView{
				isotp_conns: [IsotpConn{
					iface: 'can0'
					rx_id: 0x7A0
					tx_id: 0x7A9
					ext:   ext
				}]
			}
		}
	}
	routed := Diag{
		req: 0x7A0
		rsp: 0x7A8
		ext: true
	}
	taken := mk(routed, [other(true)])
	assert taken == ['node "gw": doip route to "zone" sends its requests on 0x7a0 (29-bit) on bus "edge", which is also the isotp rx (rx) id of "other" — it would take the routed requests as its own'], taken.str()
	assert mk(routed, [other(false)]) == []
}

// REQ-NET-021: a gateway's authored [[doip.route]] `ext` is read from its ecu.toml, and the route
// serves its node only in that format
fn test_an_authored_routes_format_is_read_from_its_ecu_toml() {
	gw_doc := fn (ext string) NodeView {
		doc := toml.parse_text('[doip]\nlogical_address = 0x0E80\n\n[[doip.route]]\nnode    = "zone"\nlogical = 0x07C0\nbus     = "can1"\ntx_id   = 0x18DA20F1\nrx_id   = 0x18DAF120\n${ext}\n') or {
			panic(err)
		}
		return parse_node_view(doc)
	}
	v := gw_doc('ext     = true')
	assert v.doip_routes.len == 1 && v.doip_routes[0].ext
	assert !gw_doc('').doip_routes[0].ext
	dir := os.join_path(os.temp_dir(), 'sysmodel_route_read_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut s := route_on_edge(dir, 0x18DA20F1, 0x18DAF120, true, [])
	s.nodes[0].view = v
	assert route_errs(s).filter(it.contains('in that format')) == []
	s.nodes[0].view = gw_doc('')
	e := route_errs(s).filter(it.contains('in that format'))
	assert e.len == 1 && e[0].contains('sends on 0x18da20f1 and listens on 0x18daf120'), e.str()
}

// REQ-TOPO-002: the NM peer range holds 11-bit alive ids, so a 29-bit diagnostic id on a number
// inside it is no alive frame; an 11-bit one is
fn test_a_29_bit_diagnostic_id_is_never_in_the_nm_peer_range() {
	nm_node := fn (ext bool) System {
		return System{
			buses: [Bus{
				name:      'compute'
				interface: 'can0'
				kind:      'can'
			}]
			nodes: [
				Node{
					name:  'a'
					buses: ['compute']
					view:  NodeView{
						has_nm:      true
						nm_enabled:  true
						nm_bus:      'can0'
						peers_lo:    0x500
						peers_hi:    0x5FF
						isotp_conns: [IsotpConn{
							iface: 'can0'
							rx_id: 0x520
							tx_id: 0x510
							ext:   ext
						}]
					}
				},
			]
		}
	}
	assert frame_errs(nm_node(true)).filter(it.contains('NM peer range')) == []
	e := frame_errs(nm_node(false)).filter(it.contains('NM peer range'))
	assert e.len == 1 && e[0].contains('isotp tx id 0x510 falls in the NM peer range [0x500,0x5ff]'), e.str()
}

// partial: a dissolved one-bus system — node "n" with `diag` (none when '') and the partial ecu.toml
// `isotp` (its [isotp] body) — loaded as sysgen and syscheck load it
fn partial(dir string, diag string, isotp_body string) System {
	os.mkdir_all(dir) or { panic(err) }
	d := if diag == '' { '' } else { 'diag  = ${diag}\n' }
	os.write_file(os.join_path(dir, 'system.toml'), '[bus.compute]\ninterface = "can0"\n\n[[node]]\nname  = "n"\necu   = "n.toml"\nbuses = ["compute"]\n${d}') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, 'n.toml'), '[isotp]\nbus = "can0"\n${isotp_body}\n') or {
		panic(err)
	}
	mut s := parse_system(os.join_path(dir, 'system.toml')) or { panic(err) }
	assert s.load_nodes_partial() == []
	return s
}

// REQ-TOPO-014: a dissolved node's [isotp] that states no ids takes its diag allocation — the ids
// every check then sees, and sysgen writes; one that states them is held to it; one with no
// allocation to take is refused
fn test_a_dissolved_nodes_isotp_takes_its_diag_allocation() {
	dir := os.join_path(os.temp_dir(), 'sysmodel_diag_lower_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	fixed := partial(dir, '{ addressing = "normal_fixed", sa = 0x10, ta = 0xF1, functional_ta = 0x33 }',
		'bs = 8')
	c := fixed.nodes[0].view.isotp_conns[0]
	assert !c.ids_stated && c.lowered
	assert c.rx_id == 0x18DA10F1 && c.tx_id == 0x18DAF110 && c.functional_id == 0x18DB33F1 && c.ext
	assert validate_system_gen(fixed).filter(it.req == 'REQ-TOPO-014') == []
	std := partial(dir, '{ req = 0x7A0, rsp = 0x7A8 }', '').nodes[0].view.isotp_conns[0]
	assert std.lowered && std.rx_id == 0x7A0 && std.tx_id == 0x7A8 && !std.ext
	// stated: kept, and held to the allocation
	stated := partial(dir, '{ req = 0x7A0, rsp = 0x7A8 }', 'rx_id = 0x7A1\ntx_id = 0x7A8')
	assert stated.nodes[0].view.isotp_conns[0].ids_stated
	assert !stated.nodes[0].view.isotp_conns[0].lowered
	assert stated.nodes[0].view.isotp_conns[0].rx_id == 0x7A1
	assert validate_system_gen(stated).filter(it.req == 'REQ-TOPO-014').len == 1
	// `ext` alone is a statement too: nothing is lowered under it
	assert partial(dir, '{ req = 0x7A0, rsp = 0x7A8 }', 'ext = true').nodes[0].view.isotp_conns[0].ids_stated
	// no allocation to take
	bare := partial(dir, '', 'bs = 8')
	e := validate_system_gen(bare).filter(it.req == 'REQ-TOPO-014')
	assert e.len == 1 && e[0].msg == 'node "n": its [isotp] states no ids, and it has no diag allocation for sysgen to lower into it — give the node a `diag` in system.toml, or state the ids in its [isotp]', e.str()
	// a refused diag is said once, by its shape check
	refused := partial(dir, '{ addressing = "normal_fixed", ta = 0xF1 }', '')
	assert validate_system_gen(refused).filter(it.req == 'REQ-TOPO-014') == []
}
