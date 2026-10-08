module netcfg

fn test_parse_is_ip4_h_rule() {
	assert parse('192.168.0.50')? == 0xC0A80032
	assert parse('192.168.0.050')? == 0xC0A80032
	for bad in ['', '192.168.0', '192.168.0.50.1', '192.168..50', '192.168.0.', '192.168.0.256',
		'192.168.0.0050', '192.168.0.5a', ' 192.168.0.5'] {
		assert parse(bad) == none, bad
	}
}

fn test_mask_ok_is_contiguous_with_room_for_a_host_and_a_gateway() {
	for good in ['255.255.255.0', '255.255.0.0', '255.0.0.0', '128.0.0.0', '255.255.255.252'] {
		assert mask_ok(parse(good)?), good
	}
	for bad in ['0.0.0.0', '255.255.255.254', '255.255.255.255', '255.0.255.0', '255.255.255.1',
		'0.255.255.255'] {
		assert !mask_ok(parse(bad)?), bad
	}
}

// absent keys resolve to exactly what driver/eth/netx_up.c did before they existed: a /24 whose
// .1 is the gateway, and nothing for the compiler
fn test_the_defaults_are_the_old_constants() {
	n, errs := resolve('192.168.0.50', none, none)
	assert errs == []
	assert n.netmask == 0xFFFFFF00
	assert n.gateway == 0xC0A80001
	assert n.c_defs() == ''
	assert host_problems(n) == []
	// and only a mask: the gateway is still the .1, of the configured subnet
	m, errs2 := resolve('10.1.2.3', '255.255.0.0', none)
	assert errs2 == []
	assert m.gateway == 0x0A010001
	assert m.c_defs() == '-DBLOB_NET_NETMASK=0xFFFF0000UL'
}

fn test_explicit_values_reach_the_compiler() {
	n, errs := resolve('192.168.1.20', '255.255.254.0', '192.168.0.254')
	assert errs == []
	assert n.c_defs() == '-DBLOB_NET_NETMASK=0xFFFFFE00UL -DBLOB_NET_GATEWAY=0xC0A800FEUL'
}

fn test_resolve_refuses_a_bad_mask_and_a_gateway_off_the_subnet() {
	_, e1 := resolve('192.168.0.50', '255.0.255.0', none)
	assert e1.len == 1 && e1[0].contains('not a contiguous mask'), e1.str()
	_, e2 := resolve('192.168.0.50', '255.255.255.x', none)
	assert e2.len == 1 && e2[0].contains('not a dotted IPv4 address'), e2.str()
	_, e3 := resolve('192.168.0.50', none, '192.168.1.1')
	assert e3 == ['gateway "192.168.1.1" is not on the subnet 192.168.0.0/255.255.255.0']
	_, e4 := resolve('192.168.0.50', none, '192.168.0.0')
	assert e4 == ['gateway "192.168.0.0" is the network address of 192.168.0.0/255.255.255.0']
	_, e5 := resolve('192.168.0.50', '255.255.0.0', '192.168.255.255')
	assert e5 == ['gateway "192.168.255.255" is the broadcast address of 192.168.0.0/255.255.0.0']
	_, e6 := resolve('192.168.0.50', none, 'gw')
	assert e6 == ['gateway "gw" is not a dotted IPv4 address']
	// present and empty is a value, and not an address
	_, e7 := resolve('192.168.0.50', '', none)
	assert e7 == ['netmask "" is not a dotted IPv4 address']
}

// on the default /24 the host rule is the old one: not .0, .1 or .255
fn test_host_problems_generalise_the_old_24_rule() {
	for last in [0, 1, 255] {
		n, _ := resolve('192.168.0.${last}', none, none)
		assert host_problems(n).len == 1, '${last}'
	}
	// on a /16, .0.255 and .1.0 are hosts, .255.255 is not
	for a in ['192.168.0.255', '192.168.1.0'] {
		n, _ := resolve(a, '255.255.0.0', none)
		assert host_problems(n) == [], a
	}
	n, _ := resolve('192.168.255.255', '255.255.0.0', none)
	assert host_problems(n) == ['address "192.168.255.255" is the broadcast address of 192.168.0.0/255.255.0.0']
	g, _ := resolve('192.168.0.50', none, '192.168.0.50')
	assert host_problems(g) == ['address "192.168.0.50" is its own gateway']
}

// the host rule's one policy: a DoIP entity's address always, any other once its subnet is set
fn test_check_judges_the_host_where_the_policy_says() {
	_, s1, h1 := check('192.168.0.1', none, none, false)
	assert s1 == [] && h1 == []
	_, _, h2 := check('192.168.0.1', none, none, true)
	assert h2 == ['address "192.168.0.1" is its own gateway']
	_, _, h3 := check('192.168.0.255', '255.255.255.0', none, false)
	assert h3.len == 1
	// a broken subnet is said, and the address is not judged on it
	_, s4, h4 := check('192.168.0.1', '255.0.255.0', none, true)
	assert s4.len == 1 && h4 == []
	// a bad address does not hide a bad mask
	_, s5, _ := check('192.168.0', '255.0.255.0', none, true)
	assert s5.len == 2, s5.str()
}

// a gateway and a host address are unicast: subnet membership alone would take a multicast one
// on a /1
fn test_a_non_unicast_gateway_or_address_is_refused() {
	_, e1 := resolve('192.168.0.50', '128.0.0.0', '224.0.0.1')
	assert e1 == ['gateway "224.0.0.1" is not a unicast address (0.x, 127.x and 224.0.0.0 and above are not)']
	_, e2 := resolve('127.0.0.5', '255.0.0.0', '127.0.0.1')
	assert e2.len == 1 && e2[0].contains('not a unicast'), e2.str()
	n, _ := resolve('239.1.2.3', none, none)
	assert host_problems(n) == ['address "239.1.2.3" is not a unicast address (0.x, 127.x and 224.0.0.0 and above are not)']
	assert unicast(0x0A000001) && !unicast(0x00000001) && !unicast(0xE0000001) && !unicast(0xFFFFFFFF)
}
