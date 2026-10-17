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
	for b in declared {
		if b.kind != 'someip' {
			s.subnet_errs << 'bus "${b.name}": `subnet` is a someip segment\'s; a CAN bus has no addresses'
			broken << b.name
			continue
		}
		text := if override != '' { override } else { b.subnet }
		from := if override != '' { '${subnet_env}: ' } else { 'bus "${b.name}": ' }
		subnets[b.name] = netcfg.parse_subnet(text) or {
			s.subnet_errs << from + err.msg()
			broken << b.name
			continue
		}
	}
	if override != '' && declared.len > 1 {
		s.subnet_errs << '${subnet_env} replaces THE segment subnet, but buses ${declared.map('"${it.name}"').join(', ')} each declare one'
		return
	}
	for mut n in s.nodes {
		if !n.has_endpoint {
			continue
		}
		on := n.buses.filter(it in subnets)
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
		if n.endpoint_netmask != none {
			s.subnet_errs << 'node "${n.name}": endpoint `netmask` is the subnet\'s on bus "${on[0]}" (${sub}) — drop it'
			continue
		}
		n.endpoint = netcfg.dotted(sub.network | u32(n.host_raw))
		if sub.prefix != 24 {
			// the /24 is driver/eth's default; any other prefix is lowered like an authored netmask
			n.endpoint_netmask = netcfg.dotted(sub.mask())
			n.netmask_from_subnet = true
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
