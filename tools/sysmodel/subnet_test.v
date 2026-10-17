module sysmodel

fn tel_system(subnet string) System {
	return System{
		buses: [
			Bus{
				name:       'tel'
				kind:       'someip'
				subnet:     subnet
				has_subnet: subnet != ''
			},
			Bus{
				name: 'can'
			},
		]
		nodes: [
			Node{
				name:         'gw'
				buses:        ['tel', 'can']
				has_endpoint: true
				has_host:     true
				host_raw:     50
			},
			Node{
				name:         'tcu'
				buses:        ['tel']
				has_endpoint: true
				has_host:     true
				host_raw:     51
			},
		]
	}
}

fn test_a_host_is_its_segment_subnet_plus_the_number() {
	mut s := tel_system('192.168.77.0/24')
	s.resolve_hosts('')
	assert s.subnet_errs == []
	assert s.nodes.map(it.endpoint) == ['192.168.77.50', '192.168.77.51']
	// the /24 is the driver's default: nothing extra is lowered
	assert s.nodes[0].endpoint_netmask == none
}

fn test_the_override_moves_every_host_and_carries_its_mask() {
	mut s := tel_system('192.168.77.0/24')
	s.resolve_hosts('10.20.0.0/16')
	assert s.subnet_errs == []
	assert s.subnet_override == '10.20.0.0/16'
	assert s.nodes.map(it.endpoint) == ['10.20.0.50', '10.20.0.51']
	assert s.nodes[0].endpoint_netmask or { '' } == '255.255.0.0'
	assert s.nodes[0].netmask_from_subnet
}

fn test_an_override_never_touches_a_system_without_a_subnet() {
	mut s := tel_system('')
	s.nodes[0] = Node{
		name:         'gw'
		buses:        ['tel']
		has_endpoint: true
		has_address:  true
		endpoint:     '192.168.0.50'
	}
	s.nodes.delete(1)
	s.resolve_hosts('10.20.0.0/16')
	assert s.subnet_errs == []
	assert s.nodes[0].endpoint == '192.168.0.50'
}

fn errs_of(mut s System, override string) []string {
	s.resolve_hosts(override)
	return s.subnet_errs
}

fn test_what_cannot_be_resolved_is_said_once() {
	// a refused subnet is one error, not one more per member
	mut s := tel_system('192.168.77.5/24')
	e := errs_of(mut s, '')
	assert e.len == 1 && e[0].contains('has host bits set'), '${e}'
	mut o := tel_system('192.168.77.0/24')
	oe := errs_of(mut o, 'bogus')
	assert oe.len == 1 && oe[0].starts_with('BLOB_NET_SUBNET: '), '${oe}'

	mut two := tel_system('192.168.77.0/24')
	two.buses[1] = Bus{
		name:       'tel2'
		kind:       'someip'
		subnet:     '192.168.78.0/24'
		has_subnet: true
	}
	assert errs_of(mut two, '10.0.0.0/24').any(it.contains('each declare one'))

	mut can := tel_system('192.168.77.0/24')
	can.buses[1].subnet = '10.0.0.0/24'
	can.buses[1].has_subnet = true
	can.nodes[1].buses = ['can']
	ce := errs_of(mut can, '')
	assert ce.len == 1 && ce[0].contains('a CAN bus has no addresses'), '${ce}'

	for i, want in [
		'gives both `address` and `host`',
		'states its subnet, so the endpoint gives `host`, not `address`',
		'must be an integer 1..254',
		'must be an integer 1..254',
		'`netmask` is the subnet',
		'needs a someip bus with a `subnet`',
	] {
		mut b := tel_system('192.168.77.0/24')
		match i {
			0 { b.nodes[1].has_address = true }
			1 { b.nodes[1] = Node{
					name:         'tcu'
					buses:        ['tel']
					has_endpoint: true
					has_address:  true
					endpoint:     '192.168.77.51'
				} }
			2 { b.nodes[1].host_raw = 255 }
			3 { b.nodes[1].host_int = false }
			4 { b.nodes[1].endpoint_netmask = '255.255.0.0' }
			else { b.nodes[1].buses = ['can'] }
		}
		e2 := errs_of(mut b, '')
		assert e2.len == 1 && e2[0].contains(want), '${i}: ${e2}'
		assert b.nodes[1].endpoint == '' || i == 1, '${i}: an unresolved host keeps no address'
	}
}
