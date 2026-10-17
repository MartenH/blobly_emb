module sysmodel

import tools.netcfg

// subnet_env: the per-bench override of a segment's `subnet` — the one setting that moves a system
// onto another network (a desk LAN, a demo router) without editing system.toml (docs/net.md)
pub const subnet_env = 'BLOB_NET_SUBNET'

// resolve_hosts derives each `host` endpoint's address from its segment's subnet — `override`
// (BLOB_NET_SUBNET) in place of the declared one — so everything downstream (the checks, sysgen's
// lowering, gen-net.env) sees an ordinary dotted address. What cannot be resolved is recorded in
// subnet_errs and the address left empty.
pub fn (mut s System) resolve_hosts(override string) {
	s.subnet_override = override
	mut subnets := map[string]netcfg.Subnet{}
	mut broken := []string{} // a bus whose subnet is refused: its members are not reported again
	declared := s.buses.filter(it.has_subnet)
	if override != '' && declared.len > 1 {
		s.subnet_errs << '${subnet_env} replaces THE segment subnet, but buses ${declared.map('"${it.name}"').join(', ')} each declare one'
		return
	}
	// the override, parsed once whichever bus it stands in for
	mut moved := ?netcfg.Subnet(none)
	if override != '' && declared.len == 1 {
		// if/else, not an `or` yielding none: V3 (e2cdd9e) emits C that does not build for that
		if m := netcfg.parse_subnet(override) {
			moved = m
		} else {
			s.subnet_errs << '${subnet_env}: ' + err.msg()
		}
	}
	for b in declared {
		if b.kind != 'someip' {
			s.subnet_errs << 'bus "${b.name}": `subnet` is a someip segment\'s; a CAN bus has no addresses'
			broken << b.name
			continue
		}
		if override != '' {
			if m := moved {
				subnets[b.name] = m
			} else {
				broken << b.name
			}
			continue
		}
		subnets[b.name] = netcfg.parse_subnet(b.subnet) or {
			s.subnet_errs << 'bus "${b.name}": ' + err.msg()
			broken << b.name
			continue
		}
	}
	mut used := map[string]bool{} // a segment some member gives its `host` on
	for mut n in s.nodes {
		if !n.has_endpoint {
			continue
		}
		on := n.buses.filter(it in subnets)
		if n.has_host {
			for b in on {
				used[b] = true
			}
		}
		if n.has_address && n.has_host {
			s.subnet_errs << 'node "${n.name}": endpoint gives both `address` and `host` — one or the other'
			continue
		}
		if n.has_address {
			if on.len > 0 {
				s.subnet_errs << 'node "${n.name}": bus "${on[0]}" states its subnet, so the endpoint gives `host`, not `address` — an address would not follow the subnet (or ${subnet_env}) when it moves'
			}
			continue
		}
		if !n.has_host {
			continue // no address at all: the segment and DoIP checks say what is missing
		}
		if n.buses.any(it in broken) {
			continue
		}
		if on.len != 1 {
			s.subnet_errs << if on.len == 0 {
				'node "${n.name}": endpoint `host` needs a someip bus with a `subnet` to be a host of — give `address` instead'
			} else {
				'node "${n.name}": endpoint `host` is ambiguous — buses ${on.map('"${it}"').join(', ')} each state a subnet'
			}
			continue
		}
		sub := subnets[on[0]]
		if !n.host_int || n.host_raw < 1 || n.host_raw > i64(sub.hosts()) {
			s.subnet_errs << 'node "${n.name}": endpoint `host` must be an integer 1..${sub.hosts()} on ${sub} (bus "${on[0]}")'
			continue
		}
		if n.host_raw == 1 {
			s.subnet_errs << 'node "${n.name}": endpoint `host` 1 is the subnet\'s gateway on ${sub} (bus "${on[0]}") — every node is brought up with .1 as its gateway'
			continue
		}
		if n.endpoint_netmask != none || n.endpoint_gateway != none {
			// a literal would not move with the subnet: the mask is the subnet's, the gateway its .1
			s.subnet_errs << 'node "${n.name}": endpoint `netmask` and `gateway` are the subnet\'s on bus "${on[0]}" (${sub}, gateway .1) — drop them'
			continue
		}
		n.endpoint = netcfg.dotted(sub.network | u32(n.host_raw))
		if sub.prefix != 24 {
			// the /24 is driver/eth's default; any other prefix is lowered like an authored netmask
			n.endpoint_netmask = netcfg.dotted(sub.mask())
			n.netmask_from_subnet = true
		}
		s.subnet_applied = override != ''
	}
	// a subnet nothing reads moves nothing: in a composed system, or beside `address` endpoints
	for b in declared {
		if b.name in subnets && b.name !in used {
			s.subnet_errs << 'bus "${b.name}": states a `subnet`, but no member\'s endpoint gives a `host` on it — it (and ${subnet_env}) would move nothing'
		}
	}
}

// check_subnets reports what resolve_hosts could not resolve
fn check_subnets(s System) []Issue {
	return s.subnet_errs.map(Issue{
		severity: .error
		req:      'REQ-TOPO-005'
		msg:      it
	})
}
