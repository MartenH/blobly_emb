module main

import toml
import comm.diagroute
import comm.doip
import tools.doipcfg
import tools.netcfg

// [doip]: the node's ONE diagnostic server — the [uds] server its [isotp] connection carries — reachable over DoIP
// (ISO 13400) too, on a ThreadX target. The server stays on the comm thread; a doip thread
// (driver/eth/doip_netx.c) runs the TCP side and hands each request across a mailbox, so CAN and
// DoIP testers share one session; a 0x27 unlock is per transport (comm/diag serve_remote).
//
// The entity's ISO 13400-2 transport policy rides beside it (tools/doipcfg reads and checks it,
// comm/doip policy.v holds the bounds and defaults): which testers may activate routing and with
// which activation types, the two TCP inactivity timers, and the boot announcements.
// DoipRoute: one node behind a DoIP gateway (REQ-NET-019) — [[doip.route]], lowered by sysgen
struct DoipRoute {
	node    string
	logical int
	bus     string // the gateway's [bus.*] the node is on
	tx_id   int    // the node's physical request id: what the gateway sends on
	rx_id   int    // its response id: what the gateway receives on
}

struct DoipCfg {
	on         bool
	address    string // the node's static IPv4 address
	netmask    ?string // its subnet mask and default gateway (none = tools/netcfg's defaults)
	gateway    ?string
	logical    int    // its DoIP logical address
	functional int    // 0 = comm/doip's default (0xE400)
	policy     doipcfg.Policy
	not_int    []string // policy keys authored as something other than integers
	routes     []DoipRoute // a gateway's: the nodes behind it diagnostics are routed to
}

const doip_vin_did = 0xF190

// ISO 13400's port, TCP and UDP (driver/eth/doip_netx.c DOIP_PORT)
const doip_port = 13400

fn parse_doip(doc toml.Doc) DoipCfg {
	dv := doc.value_opt('doip') or { return DoipCfg{} }
	dm := dv.as_map()
	policy, not_int := doipcfg.parse(dm)
	mut routes := []DoipRoute{}
	for rv in (dm['route'] or { toml.Any([]toml.Any{}) }).array() {
		r := rv.as_map()
		routes << DoipRoute{
			node:    (r['node'] or { toml.Any('') }).string()
			logical: toml_int(r, 'logical', 0, 0, 0xFFFF, '[[doip.route]]')
			bus:     (r['bus'] or { toml.Any('') }).string()
			tx_id:   toml_int(r, 'tx_id', 0, 0, 0x7FF, '[[doip.route]]')
			rx_id:   toml_int(r, 'rx_id', 0, 0, 0x7FF, '[[doip.route]]')
		}
	}
	return DoipCfg{
		on:         true
		address:    (dm['address'] or { toml.Any('') }).string()
		netmask:    opt_str(dm, 'netmask')
		gateway:    opt_str(dm, 'gateway')
		logical:    toml_int(dm, 'logical_address', 0, 0, 0xFFFF, '[doip]')
		functional: toml_int(dm, 'functional_address', 0, 0, 0xFFFF, '[doip]')
		policy:     policy
		not_int:    not_int
		routes:     routes
	}
}

// routes_on: the node is a DoIP gateway (routes diagnostics to nodes behind it)
fn routes_on(m Model) bool {
	return m.doip.on && m.doip.routes.len > 0
}

// route_bus_index: the router's index of a bus — its FDCAN index, which is also what the comm
// thread opened the bus's channel on (one channel per FDCAN)
fn route_bus_index(bus string) int {
	return fdcan_index_of(bus).int()
}

// validate_doip_routes refuses routes the gateway could not serve (REQ-NET-019/020): more than the
// runtime holds, a bus that is not one of its CAN buses, an address that is not an entity address
// or is this entity's own, one routed twice, request and response on one id, ids that are this
// node's own diagnostic ids on that bus, and a route_level its [uds] does not serve.
fn validate_doip_routes(m Model) {
	d := m.doip
	if d.routes.len == 0 {
		return
	}
	if d.routes.len > doip.max_routes || d.routes.len > diagroute.max_routes {
		panic('loom2v: [doip] routes ${d.routes.len} nodes — a gateway routes to at most ${doip.max_routes}')
	}
	mut seen := map[int]string{}
	for r in d.routes {
		where := 'loom2v: [[doip.route]] "${r.node}"'
		if r.node == '' {
			panic('loom2v: [[doip.route]] needs `node` — the routed node\'s name')
		}
		if !(m.buses[r.bus] or { false }) || (m.bus_kind[r.bus] or { 'can' }) != 'can' {
			panic('${where}: bus "${r.bus}" is not one of this node\'s CAN buses')
		}
		if m.target.threadx && !fdcan_bus_name_ok(r.bus) {
			panic('${where}: bus "${r.bus}" must be named exactly "can0" or "can1" — the comm thread opens a bus by that one-digit FDCAN index')
		}
		// the comm thread opens a route bus beside its own: under another name for the same
		// controller it would open that FDCAN twice, and its own drain would take the routed answers
		if m.target.threadx && r.bus != m.telem.bus && fdcan_index(r.bus) == fdcan_index(m.telem.bus) {
			panic('${where}: bus "${r.bus}" is FDCAN index ${fdcan_index(r.bus)}, the controller of this node\'s own bus "${m.telem.bus}" under another name — name the bus the same, or route on another controller')
		}
		// ... and drives it from its own core: a bus assigned to another core's owner is not routed
		if (m.bus_core[r.bus] or { 0 }) != (m.bus_core[m.telem.bus] or { 0 }) {
			panic('${where}: bus "${r.bus}" is on core ${m.bus_core[r.bus] or { 0 }}, the comm thread routing on core ${m.bus_core[m.telem.bus] or { 0 }} — routing through another core\'s bus owner is not supported')
		}
		if !((r.logical >= 0x0001 && r.logical <= 0x0DFF) || (r.logical >= 0x1000 && r.logical <= 0x7FFF)) {
			panic('${where}: logical 0x${r.logical.hex()} is not an entity address (0x0001..0x0DFF or 0x1000..0x7FFF)')
		}
		func_addr := if d.functional != 0 { d.functional } else { int(doip.default_functional_addr) }
		if r.logical == d.logical || r.logical == func_addr {
			panic('${where}: logical 0x${r.logical.hex()} is this entity\'s own address')
		}
		if prev := seen[r.logical] {
			panic('${where}: logical 0x${r.logical.hex()} is "${prev}"\'s route too')
		}
		seen[r.logical] = r.node
		if r.tx_id == r.rx_id {
			panic('${where}: tx_id and rx_id are one id 0x${r.tx_id.hex()} — a request would be read as its own answer')
		}
		for c in m.isotp_conns {
			mut own := [c.rx_id, c.tx_id]
			if c.functional_id != 0 { // 0: no functional id (no listener on 0)
				own << c.functional_id
			}
			if c.bus == r.bus && (r.tx_id in own || r.rx_id in own) {
				panic('${where}: its ids 0x${r.tx_id.hex()} / 0x${r.rx_id.hex()} are this node\'s own [isotp] ids on bus "${r.bus}"')
			}
		}
		// a routed exchange neither holds the network awake nor wakes it, and would transmit on a
		// bus NM has put to sleep: not supported on the bus this node runs NM on
		nm_bus := if m.target.threadx || m.nm.bus == '' { m.telem.bus } else { m.nm.bus }
		if m.nm.on && r.bus == nm_bus {
			panic('${where}: bus "${r.bus}" is the bus this node runs NM on — a routed exchange would neither hold nor wake the network; route to nodes on a bus without NM')
		}
	}
	// two routes on one bus are two nodes: they must not share a diagnostic id there
	for i, a in d.routes {
		for b in d.routes[i + 1..] {
			if a.bus == b.bus && (a.tx_id in [b.tx_id, b.rx_id] || a.rx_id in [b.tx_id, b.rx_id]) {
				panic('loom2v: [[doip.route]] "${a.node}" and "${b.node}" share a diagnostic id on bus "${a.bus}" (0x${a.tx_id.hex()} / 0x${a.rx_id.hex()} and 0x${b.tx_id.hex()} / 0x${b.rx_id.hex()}) — one request would reach both')
			}
		}
	}
	level := int(d.policy.int_of('route_level'))
	if level < 1 || level > 8 || sa_levels(m) & (u8(1) << (level - 1)) == 0 {
		panic('loom2v: [doip] route_level ${level} is not a security level this node\'s [uds] serves — a tester could never earn the unlock routing needs (REQ-NET-020)')
	}
}

// doip_route_init: on the comm thread before its loop — the router (comm/diagroute), its routes and
// the level a tester must hold (REQ-NET-020). bs 8: the gateway drains a bus's 8-deep receive FIFO
// every pass, so a routed node never sends it more consecutive frames in a burst than that.
fn doip_route_init(m Model) []string {
	if !routes_on(m) {
		return []string{}
	}
	mut g := ['\tg_droute.init(u8(${m.doip.policy.int_of('route_level')}), u8(8)) // REQ-NET-019/020: the gateway\'s router']
	for r in m.doip.routes {
		g << '\tg_droute.add(diagroute.Route{ // ${r.node}, on ${r.bus}'
		g << '\t\tlogical: u16(0x${r.logical.hex()})'
		g << '\t\tbus:     u8(${route_bus_index(r.bus)})'
		g << '\t\ttx_id:   u32(0x${r.tx_id.hex()})'
		g << '\t\trx_id:   u32(0x${r.rx_id.hex()})'
		g << '\t})'
	}
	return g
}

// doip_route_serve: after the mailbox (a dropped connection has ended its unlock first), the unlock
// the network tester holds on this node now — kept by the router for its connection once it is the
// route level — judges a routed request waiting, and the router's answers go into the route channel
fn doip_route_serve(m Model) []string {
	if !routes_on(m) {
		return []string{}
	}
	return ['\t\tdoipnet.serve_routes(mut g_droute, g_diag.remote_unlocked(), &g_rt_req[0], C.board_now_us())']
}

// doip_route_gate: the bus the routed exchange is on is drained while the router has room for
// another answer — with its queue full the bus's frames wait in the FIFO for the doip thread to
// take one, but only briefly (diagroute.gate_hold_us: the gateway's own traffic on that bus must
// not stall behind a tester that does not read). Another route bus carries no frame of the
// exchange and is drained as ever.
fn doip_route_gate(m Model, bus string) string {
	if !routes_on(m) || !m.doip.routes.any(it.bus == bus) {
		return ''
	}
	return '(g_droute.active_bus() != ${route_bus_index(bus)} || g_droute.room(C.board_now_us())) && '
}

// doip_route_arm: in the drain of bus `bus`, a frame of the routed exchange is the router's
fn doip_route_arm(m Model, bus string) []string {
	if !routes_on(m) || !m.doip.routes.any(it.bus == bus) {
		return []string{}
	}
	return [
		'\t\t\tif g_droute.on_frame(u8(${route_bus_index(bus)}), &rx, C.board_now_us()) {',
		'\t\t\t\tcontinue',
		'\t\t\t}',
	]
}

// doip_route_produce: the router's timers, then the routed exchange's frames onto its bus — ahead
// of the periodic producers, like the server's answer (a tester is timing it)
fn doip_route_produce(m Model) []string {
	if !routes_on(m) {
		return []string{}
	}
	mut g := ['\t\tg_droute.step(t1)', '\t\tmatch g_droute.active_bus() {']
	mut done := map[string]bool{}
	for r in m.doip.routes {
		if done[r.bus] {
			continue
		}
		done[r.bus] = true
		g << '\t\t\t${route_bus_index(r.bus)} { g_droute.pump(t1, mut ${gw_var(r.bus, m.telem.bus)}) }'
	}
	g << '\t\t\telse {}'
	g << '\t\t}'
	return g
}

// opt_str: a key's value as written, none when absent (ecucheck has judged its type)
fn opt_str(m map[string]toml.Any, key string) ?string {
	v := m[key] or { return none }
	return v.string()
}

// node_net: the node's ONE network (driver/eth/netx_up.c): [doip]'s address and subnet, or on a
// SOME/IP-only node its eth bus's — validate_net has made the two one where a node has both
fn node_net(m Model) netcfg.Net {
	n, _ := if m.doip.on {
		netcfg.resolve(m.doip.address, m.doip.netmask, m.doip.gateway)
	} else {
		netcfg.resolve(m.eth_iface, m.eth_netmask, m.eth_gateway)
	}
	return n
}

// validate_net refuses a subnet the target cannot bring up, by tools/netcfg's check — the rule
// syscheck applies to a system node's endpoint: a netmask or gateway that is not a dotted quad, a
// mask that is not contiguous, a gateway off the subnet or on its network or broadcast address, an
// address that is not a host of it (a DoIP entity's always — its old /24 rule — an eth bus's once
// it configures its subnet); and a subnet on a CAN bus, and two subnets on one node.
fn validate_net(m Model) {
	// a subnet is NetX's (driver/eth/netx_up.c): an image that brings none up has nothing to apply
	// it to — the host backend binds an address on the host's own network, whatever its mask
	configured := (m.doip.on && (m.doip.netmask != none || m.doip.gateway != none))
		|| (m.eth != '' && (m.eth_netmask != none || m.eth_gateway != none))
	if configured && !(m.target.threadx && (eth_thread_on(m) || m.doip.on)) {
		panic('loom2v: a netmask or gateway is configured, but this image brings up no network to apply it to (a ThreadX target with [doip] or SOME/IP on its eth bus); the host binds an address on the host\'s own network')
	}
	for k in m.non_eth_net_keys {
		panic('loom2v: [bus.${k} is an eth bus\'s key (its interface is an address); a CAN bus has no subnet')
	}
	if m.doip.on {
		d := m.doip
		if netcfg.parse(d.address) == none {
			panic('loom2v: [doip] address "${d.address}" is not a dotted IPv4 address')
		}
		net_refusals('[doip]', 'address "${d.address}"', d.address, d.netmask, d.gateway, true)
	}
	if m.eth != '' {
		net_refusals('[bus.${m.eth}]', 'interface "${m.eth_iface}"', m.eth_iface, m.eth_netmask,
			m.eth_gateway, false)
	}
	// one NetX per image, so one subnet: what [doip] and the eth bus say must be one (the address
	// itself: validate_doip) — where the eth bus is brought up, or states a subnet of its own
	if m.doip.on && m.eth != '' && (eth_thread_on(m) || m.eth_netmask != none || m.eth_gateway != none) {
		a, _ := netcfg.resolve(m.doip.address, m.doip.netmask, m.doip.gateway)
		b, _ := netcfg.resolve(m.eth_iface, m.eth_netmask, m.eth_gateway)
		if a.netmask != b.netmask || a.gateway != b.gateway {
			panic('loom2v: [doip] subnet ${a.subnet()} gateway ${netcfg.dotted(a.gateway)} differs from eth bus "${m.eth}"\'s ${b.subnet()} gateway ${netcfg.dotted(b.gateway)} — a node has one network')
		}
	}
}

// net_refusals: netcfg.check's verdict on one place an address is declared, as a refusal
fn net_refusals(table string, what string, address string, netmask ?string, gateway ?string, entity bool) {
	if netmask == none && gateway == none && !entity {
		return // nothing configured: driver/eth's defaults, judged nowhere before either
	}
	_, subnet, host := netcfg.check(address, netmask, gateway, entity)
	for e in subnet {
		panic('loom2v: ${table} ${e}')
	}
	for e in host {
		panic('loom2v: ${table} ${what} is not a host address on its subnet: ${e}')
	}
}

// ip4_octets: the address as numbers, so 192.168.0.050 and 192.168.0.50 are one address
fn ip4_octets(s string) []int {
	return s.split('.').map(it.int())
}

// doip_vin: the VIN DoIP announces is DID 0xF190's value — one answer, whichever transport asks
fn doip_vin(m Model) string {
	for d in m.dids {
		if d.id == doip_vin_did {
			return d.bytes.bytestr()
		}
	}
	return ''
}

// validate_doip refuses a [doip] the target cannot carry, or one that would expose more over IP
// than docs/net.md's security posture allows.
fn validate_doip(m Model) {
	if !m.doip.on {
		return
	}
	d := m.doip
	if !m.target.threadx {
		panic('loom2v: [doip] is a ThreadX target transport (driver/eth/doip_netx.c); a host node has none yet')
	}
	if m.isotp_conns.len != 1 {
		panic('loom2v: [doip] carries the node\'s ONE diagnostic server — declare its [uds] server and [isotp] connection')
	}
	// one NetX per image, at one address (driver/eth/netx_up.c): SOME/IP and DoIP share it
	if eth_thread_on(m) && ip4_octets(m.eth_iface) != ip4_octets(d.address) {
		panic('loom2v: [doip] address "${d.address}" differs from eth bus "${m.eth}" interface "${m.eth_iface}" — a node has one address')
	}
	// and one UDP 13400: DoIP's announcement/identification socket owns it
	if eth_thread_on(m) && m.someip.port == doip_port {
		panic('loom2v: [someip] port ${doip_port} is DoIP\'s (UDP 13400, ISO 13400) on this node — pick another')
	}
	// ISO 13400-2: DoIP entities take 0x0001..0x0DFF and 0x1000..0x7FFF (0x0E00..0x0FFF are testers)
	if !((d.logical >= 0x0001 && d.logical <= 0x0DFF) || (d.logical >= 0x1000 && d.logical <= 0x7FFF)) {
		panic('loom2v: [doip] logical_address 0x${d.logical.hex()} is not an entity address (0x0001..0x0DFF or 0x1000..0x7FFF)')
	}
	fk := schema_key('doip', 'functional_address')
	if d.functional != 0 && !fk.in_range(d.functional) {
		panic('loom2v: [doip] functional_address 0x${d.functional.hex()} is outside the functional range 0x${fk.min:X}..0x${fk.max:X}')
	}
	for k in d.not_int {
		panic('loom2v: [doip] `${k}` must be an integer (a list: of integers) — narrowed it would be a different value')
	}
	problems := d.policy.problems()
	if problems.len > 0 {
		panic('loom2v: [doip] ${problems.join('; ')}')
	}
	for did in m.dids {
		// announced at boot and answered by 0x22 alike: a write would make the two disagree
		if did.id == doip_vin_did && did.writable {
			panic('loom2v: [doip] announces DID 0xF190 as the VIN: it cannot be writable')
		}
	}
	vin := doip_vin(m)
	if vin.len != 17 || !vin.bytes().all(it >= 0x21 && it <= 0x7E) {
		panic('loom2v: [doip] announces DID 0xF190 as the VIN: declare it as 17 printable ASCII characters (got "${vin}")')
	}
	// REQ-NET-012: over IP, reachability alone must not change ECU state. comm/diag makes an
	// unlock the transport's that earned it, so a level asked over DoIP is the network tester's
	// own 0x27, never the bus tester's. A write: the DID's own write gate, or the 0x2E row's
	// (comm/uds checks the row first, so a gated row denies every DID behind it)
	mut wrows := []doipcfg.ServiceRow{}
	for r in m.uds.services {
		wrows << doipcfg.ServiceRow{
			sid:      r.sid
			security: i64(r.security)
		}
	}
	mut dws := []doipcfg.DidWrite{}
	for did in m.dids {
		dws << doipcfg.DidWrite{
			id:       did.id
			writable: did.writable
			security: i64(did.write_security)
		}
	}
	for why in doipcfg.did_refusals(wrows, dws) {
		panic('loom2v: [doip] ${why}')
	}
	// ...every other service: doipcfg's rule, the one syscheck applies too (fail-closed: no table
	// is refused outright, and a row the rule does not exempt needs a level)
	mut rows := []doipcfg.ServiceRow{}
	for r in m.uds.services {
		rows << doipcfg.ServiceRow{
			sid:      r.sid
			security: i64(r.security)
		}
	}
	for why in doipcfg.service_refusals(m.uds.table, rows) {
		panic('loom2v: [doip] ${why}')
	}
	// ...the handoff into the bootloader included, which 0x10's exemption does not cover
	hand := doipcfg.handoff_refusal(m.boot.on, i64(m.uds.handoff_security))
	if hand != '' {
		panic('loom2v: [doip] ${hand}')
	}
	// ...and the key that level is checked with must not be one anybody can compute
	why := doipcfg.bench_key_refusal(m.uds.security_key, d.policy.allow_bench_key)
	if why != '' {
		panic('loom2v: [doip] ${why}')
	}
	validate_doip_routes(m)
}

// doip_target_fns: the C seam and the doip threads' entry points. The loop itself is
// driver/doipnet's — the same one the node's bootloader runs (boot/target) — over
// driver/eth/doip_netx.c, which calls these once its sockets are up.
fn doip_target_fns(m Model) []string {
	if !m.doip.on {
		return []string{}
	}
	mut g := [
		'',
		'fn C.doip_net_create(&char, u32, u32) int',
		'fn C.doip_net_timers(u32, u32)',
		'fn C.doip_net_seed(u32)',
		'fn C.doip_net_tcb(int) voidptr',
		'fn C.doip_mb_init(&u8, &u8)',
	]
	if routes_on(m) {
		g << 'fn C.doip_rt_init(&u8, &u8)'
	}
	if sa_levels(m) == 0 {
		// the TCP sequence-number seed comes from the board TRNG (declared with 0x27 otherwise)
		g << 'fn C.diag_sa_init() int'
		g << 'fn C.diag_sa_seed(&u8, int) int'
	}
	p := m.doip.policy
	g << ''
	g << '// doip_run: the doip thread — the boot announcements, then one tester at a time ([doip]'
	g << '// announce_count / announce_interval_ms); the server is the comm thread\'s, across the mailbox'
	g << "@[export: 'blobly_doip_run']"
	g << 'fn doip_run() {'
	if routes_on(m) {
		g << '\tdoipnet.run_gateway(mut g_doip, ${p.int_of('announce_count')}, ${p.int_of('announce_interval_ms')}, &g_doip_in[0], &g_doip_out[0], &g_rt_ans[0])'
	} else {
		g << '\tdoipnet.run(mut g_doip, ${p.int_of('announce_count')}, ${p.int_of('announce_interval_ms')}, &g_doip_in[0], &g_doip_out[0])'
	}
	g << '}'
	g << ''
	g << '// doip_udp: a request on UDP 13400 (the doip-svc thread) — identification, entity status, power'
	g << '// mode; identity is set at boot'
	g << "@[export: 'blobly_doip_udp']"
	g << 'fn doip_udp(req &u8, n int, resp &u8) int {'
	g << '\treturn doipnet.udp(&g_doip, req, n, resp)'
	g << '}'
	return g
}

// doip_target_globals: the DoIP framing state and its buffers, and the mailbox's two buffers —
// bss, sized by comm/doip's constants (the comm thread's server answers within doip.max_uds).
fn doip_target_globals(m Model) []string {
	if !m.doip.on {
		return []string{}
	}
	mut g := [
		'\tg_doip      doip.Server // DoIP framing on the doip thread; the server is g_diag\'s',
		'\tg_doip_in   [doip.max_msg]u8',
		'\tg_doip_out  [doip.max_resp]u8',
		'\tg_doip_req  [doip.max_msg]u8 // the mailbox: a request on its way to the comm thread',
		'\tg_doip_resp [doip.max_uds]u8 // ... and its answer on the way back',
	]
	if routes_on(m) {
		g << '\tg_droute   diagroute.Router // the gateway\'s routes (REQ-NET-019), on the comm thread'
		g << '\tg_rt_req   [doip.max_uds]u8 // the route channel: a routed request on its way to it'
		g << '\tg_rt_ans   [doip.max_uds]u8 // ... and a routed node\'s answer on the way back'
	}
	return g
}

// doip_net_prio: the network runs below every application thread of this image (a bigger number is a
// lower priority) — a LAN flood keeps NetX's deferred receive work busy, and with no time slicing a
// thread at the same priority as the CAN owner or an FB thread would never yield to it. Diagnostics
// over IP are best effort; the FBs' periods and the bus are not.
fn doip_net_prio(m Model) int {
	return lowest_app_prio(m) + 1
}

// doip_target_create: in tx_application_define, before any thread runs — the identity the
// identification thread answers with, the mailbox, NetX and the two doip threads (doip_net_prio).
fn doip_target_create(m Model) []string {
	if !m.doip.on {
		return []string{}
	}
	d := m.doip
	np := doip_net_prio(m)
	if np + 1 > 31 {
		panic('loom2v: [doip]: its threads run below every application thread, at ${np} and ${np + 1} — ' +
			'past ThreadX\'s 0..31; give the application threads priorities up to 29')
	}
	mut g := [
		'\tg_doip.entity_addr = u16(0x${d.logical.hex()})',
	]
	if d.functional != 0 {
		g << '\tg_doip.functional_addr = u16(0x${d.functional.hex()})'
	}
	// the VIN, DID 0xF190, byte by byte: the generated runtime holds fixed arrays, no strings
	g << '\t// VIN ${doip_vin(m)} (DID 0xF190)'
	for i, b in doip_vin(m).bytes() {
		g << '\tg_doip.vin[${i}] = u8(0x${b.hex()})'
	}
	// the routing-activation policy (comm/doip policy.v; none listed = its defaults)
	p := d.policy
	if p.has_testers {
		for i, t in p.testers {
			g << '\tg_doip.testers[${i}] = u16(0x${t.hex()})'
		}
		g << '\tg_doip.n_testers = ${p.testers.len}'
	}
	if p.has_types {
		for i, t in p.types {
			g << '\tg_doip.act_types[${i}] = u8(0x${t.hex()})'
		}
		g << '\tg_doip.n_act_types = ${p.types.len}'
	}
	g << '\tg_doip.serve.answer = doipnet.answer // the comm thread\'s server, across the mailbox'
	g << '\tC.doip_mb_init(&g_doip_req[0], &g_doip_resp[0])'
	if routes_on(m) {
		// a gateway: the nodes behind it, and the hook to the comm thread's router
		for i, r in d.routes {
			g << '\tg_doip.routes[${i}] = u16(0x${r.logical.hex()}) // ${r.node}'
		}
		g << '\tg_doip.n_routes = ${d.routes.len}'
		g << '\tg_doip.serve.route = doipnet.route // the comm thread\'s router, across the route channel'
		g << '\tC.doip_rt_init(&g_rt_req[0], &g_rt_ans[0])'
	}
	g << '\tC.doip_net_timers(u32(${p.int_of('initial_inactivity_ms')}), u32(${p.int_of('general_inactivity_ms')})) // T_TCP_Initial / T_TCP_General_Inactivity'
	// below every application thread (doip_net_prio): the IP thread, then the doip threads
	g << "\tC.doip_net_create(c'${d.address}', u32(${np}), u32(${np + 1})) // -1: DoIP stays down, the node runs on"
	return g
}

// doip_target_trace_binds: the three threads doip_netx.c runs, bound in manifest order
fn doip_target_trace_binds(m Model) []string {
	if !m.doip.on {
		return []string{}
	}
	return [
		'\tC.trace_bind_thread(C.doip_net_tcb(0)) // NetX IP thread',
		'\tC.trace_bind_thread(C.doip_net_tcb(1)) // doip',
		'\tC.trace_bind_thread(C.doip_net_tcb(2)) // doip-svc',
	]
}

// doip_manifest_rows: their trace rows (thread,id,name,core,prio), in bind order
fn doip_manifest_rows(m Model, tid int) []string {
	if !m.doip.on {
		return []string{}
	}
	return [
		'thread,${tid},nx_ip,0,${doip_net_prio(m)}',
		'thread,${tid + 1},doip,0,${doip_net_prio(m) + 1}',
		'thread,${tid + 2},doip_svc,0,${doip_net_prio(m) + 1}',
	]
}

// doip_target_init: on the comm thread before its loop — the TRNG word NetX draws TCP sequence
// numbers from (driver/eth/netx_up.c blob_net_seed; 0 = none: the chip id, distinct but not secret,
// and no TRNG words folded into later draws).
fn doip_target_init(m Model) []string {
	if !m.doip.on {
		return []string{}
	}
	return [
		'\tmut doip_sb := [4]u8{}',
		'\tmut doip_seed := u32(0)',
		'\tif C.diag_sa_init() != 0 && C.diag_sa_seed(&doip_sb[0], 4) != 0 {',
		'\t\tdoip_seed = u32(doip_sb[0]) | (u32(doip_sb[1]) << 8) | (u32(doip_sb[2]) << 16) | (u32(doip_sb[3]) << 24)',
		'\t}',
		'\tC.doip_net_seed(doip_seed)',
	]
}

// doip_target_serve: the top of every pass, after housekeep — what the doip thread reported (an
// answer sent: a reset waiting on it may go; a connection dropped: what it opened ends), then a
// request waiting in the mailbox, served by the one server (driver/doipnet serve_mailbox — the
// bootloader's serve loop runs the same).
fn doip_target_serve(m Model) []string {
	if !m.doip.on {
		return []string{}
	}
	return ['\t\tdoipnet.serve_mailbox(mut g_diag, &g_doip_req[0], &g_doip_resp[0])']
}

// doip_reset_wait: before the MCU resets, the DoIP answers already handed to TCP leave it — bounded,
// as the CAN wait is (a peer that never acknowledges gets the reset all the same)
fn doip_reset_wait(m Model) []string {
	if !m.doip.on {
		return []string{}
	}
	return ['\t\t\tdoipnet.drain_tx(diag_now_us)']
}

// bus_opt: [bus.<name>].<key> as written, none when absent
fn bus_opt(doc toml.Doc, name string, key string) ?string {
	if name == '' {
		return none
	}
	bv := doc.value_opt('bus') or { return none }
	bc := bv.as_map()[name] or { return none }
	return opt_str(bc.as_map(), key)
}

// non_eth_net_keys: "<bus> `netmask`" for each subnet key on a bus that is not the eth one
fn non_eth_net_keys(doc toml.Doc, bus_kind map[string]string) []string {
	mut out := []string{}
	for name, kind in bus_kind {
		if kind == 'eth' {
			continue
		}
		for key in ['netmask', 'gateway'] {
			if bus_opt(doc, name, key) != none {
				out << '${name}] `${key}`'
			}
		}
	}
	out.sort()
	return out
}

// bus_interface: [bus.<name>].interface ('' = no such bus or no interface)
fn bus_interface(doc toml.Doc, name string) string {
	if name == '' {
		return ''
	}
	bv := doc.value_opt('bus') or { return '' }
	bc := bv.as_map()[name] or { return '' }
	return (bc.as_map()['interface'] or { toml.Any('') }).string()
}

// net_build_lines: what a target image links for its network, for gen/loom_build.mk — the shared
// NetX bring-up and whichever seams the config asks for, so no node's Makefile lists them by hand.
// Paths are the including Makefile's REPO and BOARD.
fn net_build_lines(m Model) string {
	if !m.target.threadx || (!eth_thread_on(m) && !m.doip.on) {
		return 'LOOM_NET_SRCS :=\nLOOM_NET_DEFS :=\n'
	}
	mut srcs := [r'$(REPO)/boards/$(BOARD)/eth.c', r'$(REPO)/net/nx_driver_stm32h7.c',
		r'$(REPO)/driver/eth/netx_up.c']
	if eth_thread_on(m) {
		// the SOME/IP seam, and the byte IOC its signals cross threads through
		srcs << r'$(REPO)/driver/eth/eth_netx.c'
		srcs << r'$(REPO)/boards/common/iocb.c'
	}
	if m.doip.on {
		srcs << r'$(REPO)/driver/eth/doip_netx.c'
	}
	// the shared pool: SOME/IP 8, DoIP 12 (the TCP window and its socket), both 16
	pool := if eth_thread_on(m) && m.doip.on { 16 } else if m.doip.on { 12 } else { 8 }
	// the subnet the node configures (tools/netcfg c_defs; none = driver/eth's /24 and .1 gateway),
	// for the application here and for a [doip] node's bootloader through boot/boot.mk
	addr := node_net(m).c_defs()
	defs := if addr == '' { '' } else { ' ${addr}' }
	return 'LOOM_NET_SRCS = ${srcs.join(' ')}\nLOOM_NET_ADDR_DEFS :=${defs}\nLOOM_NET_DEFS := -DBLOB_NET_POOL_COUNT=${pool}u${defs}\n'
}
