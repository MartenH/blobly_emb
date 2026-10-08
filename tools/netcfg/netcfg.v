// netcfg — a node's IPv4 network as configuration, BUILD-TIME: its address, netmask and default
// gateway, as system.toml's `endpoint` and ecu.toml's [doip] / eth [bus.*] spell them. One parser
// and one checker, so the schema's leaf check (cfgschema), syscheck (sysmodel) and the node gate
// (loom2v) cannot disagree. The target brings the network up in driver/eth/netx_up.c, which takes
// an explicit netmask and gateway as BLOB_NET_NETMASK / BLOB_NET_GATEWAY (gen/loom_build.mk
// LOOM_NET_ADDR_DEFS) and otherwise applies the defaults below.
module netcfg

// default_netmask: a /24, what driver/eth/netx_up.c brings a node up on when none is configured
pub const default_netmask = '255.255.255.0'

// parse: a dotted quad, each octet one to three decimal digits and at most 255 — what
// driver/eth/ip4.h reads (a leading zero is decimal there and here: 192.168.0.050 is .50), less its
// tolerance of a fourth leading zero, which the [doip] address never had
pub fn parse(s string) ?u32 {
	parts := s.split('.')
	if parts.len != 4 {
		return none
	}
	mut a := u32(0)
	for p in parts {
		if p.len == 0 || p.len > 3 || !p.bytes().all(it >= `0` && it <= `9`) || p.int() > 255 {
			return none
		}
		a = (a << 8) | u32(p.int())
	}
	return a
}

// dotted: an address as a dotted quad
pub fn dotted(a u32) string {
	return '${a >> 24}.${(a >> 16) & 0xFF}.${(a >> 8) & 0xFF}.${a & 0xFF}'
}

// mask_ok: ones then zeros, /1 to /30 — a subnet with room for a network address, a host, a
// gateway and a broadcast address
pub fn mask_ok(m u32) bool {
	host := ~m
	return m != 0 && host >= 3 && (host & (host + 1)) == 0
}

// default_gateway: the .1 of the subnet, what driver/eth/netx_up.c sets when none is configured
pub fn default_gateway(address u32, mask u32) u32 {
	return (address & mask) | 1
}

// Net is a node's network, resolved: every field set, defaults applied.
pub struct Net {
pub:
	address u32
	netmask u32
	gateway u32
	// what was configured rather than defaulted — only these reach the target build
	has_netmask bool
	has_gateway bool
}

pub fn (n Net) network() u32 {
	return n.address & n.netmask
}

pub fn (n Net) broadcast() u32 {
	return n.network() | ~n.netmask
}

// subnet: "192.168.0.0/255.255.255.0", for a message
pub fn (n Net) subnet() string {
	return '${dotted(n.network())}/${dotted(n.netmask)}'
}

// resolve: the network at `address` with its optional `netmask` and `gateway` (none = absent: the
// defaults), and every problem with it — a value that is not a dotted quad, a mask that is not
// contiguous, a gateway outside the subnet or on its network or broadcast address. The address
// itself is judged by host_problems, which only a caller that brings the address up asks.
pub fn resolve(address string, netmask ?string, gateway ?string) (Net, []string) {
	mut errs := []string{}
	a := parse(address) or {
		errs << 'address "${address}" is not a dotted IPv4 address'
		u32(0)
	}
	mut m := u32(0xFFFFFF00)
	if nm := netmask {
		if pm := parse(nm) {
			m = pm
			if !mask_ok(m) {
				errs << 'netmask "${nm}" is not a contiguous mask of /1../30 (ones, then zeros, with room for a host and a gateway)'
			}
		} else {
			errs << 'netmask "${nm}" is not a dotted IPv4 address'
		}
	}
	mut g := default_gateway(a, m)
	if gw := gateway {
		g = parse(gw) or {
			errs << 'gateway "${gw}" is not a dotted IPv4 address'
			g
		}
	}
	n := Net{
		address:     a
		netmask:     m
		gateway:     g
		has_netmask: netmask != none
		has_gateway: gateway != none
	}
	if errs.len > 0 {
		return n, errs
	}
	if g & m != n.network() {
		errs << 'gateway "${dotted(g)}" is not on the subnet ${n.subnet()}'
	} else if g == n.network() {
		errs << 'gateway "${dotted(g)}" is the network address of ${n.subnet()}'
	} else if g == n.broadcast() {
		errs << 'gateway "${dotted(g)}" is the broadcast address of ${n.subnet()}'
	}
	return n, errs
}

// host_problems: the address as a HOST of its subnet — not its network or broadcast address and
// not its gateway. Asked of every address driver/eth brings up as a DoIP entity, and of any whose
// netmask or gateway is configured; on the default /24 this is the old rule: not .0, .1 or .255.
pub fn host_problems(n Net) []string {
	a := dotted(n.address)
	if n.address == n.network() {
		return ['address "${a}" is the network address of ${n.subnet()}']
	}
	if n.address == n.broadcast() {
		return ['address "${a}" is the broadcast address of ${n.subnet()}']
	}
	if n.address == n.gateway {
		return ['address "${a}" is its own gateway']
	}
	return []string{}
}

// check: resolve, and the address judged as a HOST of its subnet (host_problems) where it is brought
// up as a DoIP entity (`entity`) or its subnet is configured — the one policy both syscheck and the
// node gate apply. Returns the subnet's problems and the address's apart, so a caller can say
// which is wrong; the address is judged only on a sound subnet.
pub fn check(address string, netmask ?string, gateway ?string, entity bool) (Net, []string, []string) {
	n, errs := resolve(address, netmask, gateway)
	if errs.len > 0 || !(entity || n.has_netmask || n.has_gateway) {
		return n, errs, []string{}
	}
	return n, errs, host_problems(n)
}

// c_defs: the compiler flags that carry what was CONFIGURED to driver/eth/netx_up.c — nothing for
// a default, which the C states itself, so a node without the keys builds exactly as before
pub fn (n Net) c_defs() string {
	mut d := []string{}
	if n.has_netmask {
		d << '-DBLOB_NET_NETMASK=0x${n.netmask:08X}UL'
	}
	if n.has_gateway {
		d << '-DBLOB_NET_GATEWAY=0x${n.gateway:08X}UL'
	}
	return d.join(' ')
}
