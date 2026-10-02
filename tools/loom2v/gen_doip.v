module main

import toml
import tools.doipcfg

// [doip]: the node's ONE diagnostic server — the [uds] server its [isotp] connection carries — reachable over DoIP
// (ISO 13400) too, on a ThreadX target. The server stays on the comm thread; a doip thread
// (driver/eth/doip_netx.c) runs the TCP side and hands each request across a mailbox, so CAN and
// DoIP testers share one session; a 0x27 unlock is per transport (comm/diag serve_remote).
//
// The entity's ISO 13400-2 transport policy rides beside it (tools/doipcfg reads and checks it,
// comm/doip policy.v holds the bounds and defaults): which testers may activate routing and with
// which activation types, the two TCP inactivity timers, and the boot announcements.
struct DoipCfg {
	on         bool
	address    string // the node's static IPv4 address
	logical    int    // its DoIP logical address
	functional int    // 0 = comm/doip's default (0xE400)
	policy     doipcfg.Policy
	not_int    []string // policy keys authored as something other than integers
}

const doip_vin_did = 0xF190

// ISO 13400's port, TCP and UDP (driver/eth/doip_netx.c DOIP_PORT)
const doip_port = 13400

fn parse_doip(doc toml.Doc) DoipCfg {
	dv := doc.value_opt('doip') or { return DoipCfg{} }
	dm := dv.as_map()
	policy, not_int := doipcfg.parse(dm)
	return DoipCfg{
		on:         true
		address:    (dm['address'] or { toml.Any('') }).string()
		logical:    int((dm['logical_address'] or { toml.Any(0) }).int())
		functional: int((dm['functional_address'] or { toml.Any(0) }).int())
		policy:     policy
		not_int:    not_int
	}
}

// ip4_octets: the address as numbers, so 192.168.0.050 and 192.168.0.50 are one address
fn ip4_octets(s string) []int {
	return s.split('.').map(it.int())
}

// ip4_ok: a dotted quad, each octet 0..255 with at least one digit (driver/eth/ip4.h's rule), and
// a HOST on the /24 doip_net_create assumes: not .0 (the network), .255 (its broadcast) or .1 (the
// gateway it sets)
fn ip4_ok(s string) bool {
	parts := s.split('.')
	if parts.len != 4 {
		return false
	}
	for p in parts {
		if p.len == 0 || p.len > 3 || !p.bytes().all(it >= `0` && it <= `9`) || p.int() > 255 {
			return false
		}
	}
	return parts[3].int() !in [0, 1, 255]
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
	if !ip4_ok(d.address) {
		panic('loom2v: [doip] address "${d.address}" is not a host address on its /24 (dotted quad, not .0, .1 or .255)')
	}
	// ISO 13400-2: DoIP entities take 0x0001..0x0DFF and 0x1000..0x7FFF (0x0E00..0x0FFF are testers)
	if !((d.logical >= 0x0001 && d.logical <= 0x0DFF) || (d.logical >= 0x1000 && d.logical <= 0x7FFF)) {
		panic('loom2v: [doip] logical_address 0x${d.logical.hex()} is not an entity address (0x0001..0x0DFF or 0x1000..0x7FFF)')
	}
	if d.functional != 0 && (d.functional < 0xE400 || d.functional > 0xEFFF) {
		panic('loom2v: [doip] functional_address 0x${d.functional.hex()} is outside the functional range 0xE400..0xEFFF')
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
	// ...and the key that level is checked with must not be one anybody can compute
	why := doipcfg.bench_key_refusal(m.uds.security_key, d.policy.allow_bench_key)
	if why != '' {
		panic('loom2v: [doip] ${why}')
	}
}

// doip_target_fns: the C seam, the hook into the comm thread's server, and the doip thread's loop
// (the doip thread runs it; driver/eth/doip_netx.c calls it once its sockets are up).
fn doip_target_fns(m Model) []string {
	if !m.doip.on {
		return []string{}
	}
	mut g := [
		'',
		'fn C.doip_net_create(&char, u32, u32) int',
		'fn C.doip_net_timers(u32, u32)',
		'fn C.doip_stream_open() int',
		'fn C.doip_net_seed(u32)',
		'fn C.doip_net_tcb(int) voidptr',
		'fn C.doip_mb_init(&u8, &u8)',
		'fn C.doip_mb_call(&u8, int, int, &u8, int) int',
		'fn C.doip_mb_take(&int) int',
		'fn C.doip_mb_answer(int)',
		'fn C.doip_tx_pending() int',
		'fn C.doip_mb_take_sent() int',
		'fn C.doip_mb_take_dropped() int',
		'fn C.doip_stream_recv(&u8, int, u32) int',
		'fn C.doip_stream_send(&u8, int) int',
		'fn C.doip_stream_drop()',
		'fn C.doip_stream_notify_activated(int)',
		'fn C.doip_udp_broadcast(&u8, int)',
		'fn C.doip_eid(&u8)',
		'fn C.doip_sleep_ms(int)',
	]
	if sa_levels(m) == 0 {
		// the TCP sequence-number seed comes from the board TRNG (declared with 0x27 otherwise)
		g << 'fn C.diag_sa_init() int'
		g << 'fn C.diag_sa_seed(&u8, int) int'
	}
	g << ''
	g << '// doip_answer: comm/doip\'s hook to the node\'s one diagnostic server, served on the comm thread'
	g << 'fn doip_answer(ctx voidptr, req &u8, n int, functional bool, resp &u8, cap int) int {'
	g << '\treturn C.doip_mb_call(req, n, int(functional), resp, cap)'
	g << '}'
	g << ''
	g << '// doip_run: the boot announcements, then one tester at a time. A dropped connection is the'
	g << '// C side\'s to report to the comm thread; here only the DoIP framing state is reset.'
	g << "@[export: 'blobly_doip_run']"
	g << 'fn doip_run() {'
	ann_count := m.doip.policy.int_of('announce_count')
	if ann_count > 0 {
		g << '\tmut eid := [6]u8{}'
		g << '\tC.doip_eid(&eid[0])'
		g << '\tmut ann := [64]u8{}'
		g << '\tan := g_doip.announcement(&eid[0], &ann[0])'
		g << '\t// A_DoIP_Announce_Num, A_DoIP_Announce_Interval apart ([doip] announce_count / announce_interval_ms)'
		g << '\tfor i in 0 .. ${ann_count} {'
		g << '\t\tif i > 0 {'
		g << '\t\t\tC.doip_sleep_ms(${m.doip.policy.int_of('announce_interval_ms')})'
		g << '\t\t}'
		g << '\t\tC.doip_udp_broadcast(&ann[0], an)'
		g << '\t}'
	}
	g << '\tfor {'
	g << '\t\t// only what the assembly buffer can still take'
	g << '\t\tn := C.doip_stream_recv(&g_doip_in[0], doip.max_msg - g_doip.buf_len, 100)'
	g << '\t\tif n < 0 {'
	g << '\t\t\tdoip_end()'
	g << '\t\t\tcontinue'
	g << '\t\t}'
	g << '\t\tif n == 0 {'
	g << '\t\t\tcontinue'
	g << '\t\t}'
	g << '\t\t// feed stops consuming when the response buffer fills: drain with len-0 feeds'
	g << '\t\tmut fed := n'
	g << '\t\tfor {'
	g << '\t\t\trlen := g_doip.feed(&g_doip_in[0], fed, &g_doip_out[0], g_doip_out.len)'
	g << '\t\t\tif rlen <= 0 {'
	g << '\t\t\t\tbreak'
	g << '\t\t\t}'
	g << '\t\t\tif C.doip_stream_send(&g_doip_out[0], rlen) < 0 {'
	g << '\t\t\t\tdoip_end() // the C side recycled the connection'
	g << '\t\t\t\tbreak'
	g << '\t\t\t}'
	g << '\t\t\tfed = 0'
	g << '\t\t}'
	g << '\t\tif g_doip.fatal {'
	g << '\t\t\tC.doip_stream_drop() // the response that closes the socket is sent: a desynced stream\'s NACK, or a refusal'
	g << '\t\t\tdoip_end()'
	g << '\t\t}'
	g << '\t\t// the short initial idle limit holds until routing is activated'
	g << '\t\tC.doip_stream_notify_activated(if g_doip.activated { 1 } else { 0 })'
	g << '\t}'
	g << '}'
	g << ''
	g << 'fn doip_end() {'
	g << '\tg_doip.activated = false'
	g << '\tg_doip.fatal = false'
	g << '\tg_doip.buf_len = 0'
	g << '\tC.doip_stream_notify_activated(0) // the next connection gets the initial inactivity limit'
	g << '}'
	g << ''
	g << '// doip_udp: a request on UDP 13400 (the doip-svc thread) — identification, entity status, power'
	g << '// mode; identity is set at boot'
	g << "@[export: 'blobly_doip_udp']"
	g << 'fn doip_udp(req &u8, n int, resp &u8) int {'
	g << '\tmut eid := [6]u8{}'
	g << '\tC.doip_eid(&eid[0])'
	g << '\treturn g_doip.udp_response(req, n, &eid[0], C.doip_stream_open(), resp)'
	g << '}'
	return g
}

// doip_target_globals: the DoIP framing state and its buffers, and the mailbox's two buffers —
// bss, sized by comm/doip's constants (the comm thread's server answers within doip.max_uds).
fn doip_target_globals(m Model) []string {
	if !m.doip.on {
		return []string{}
	}
	return [
		'\tg_doip      doip.Server // DoIP framing on the doip thread; the server is g_diag\'s',
		'\tg_doip_in   [doip.max_msg]u8',
		'\tg_doip_out  [doip.max_resp]u8',
		'\tg_doip_req  [doip.max_msg]u8 // the mailbox: a request on its way to the comm thread',
		'\tg_doip_resp [doip.max_uds]u8 // ... and its answer on the way back',
	]
}

// doip_net_prio: the network runs below every application thread of this image (a bigger number is a
// lower priority) — a LAN flood keeps NetX's deferred receive work busy, and with no time slicing a
// thread at the same priority as the CAN owner or an FB thread would never yield to it. Diagnostics
// over IP are best effort; the FBs' periods and the bus are not.
fn doip_net_prio(m Model) int {
	mut lowest := 0
	for pname, thrs in m.part.threads_of {
		if m.part.external[pname] {
			continue
		}
		for t in thrs {
			p := m.part.thread_prio[t] or { 10 }
			if p > lowest {
				lowest = p
			}
		}
	}
	if lowest == 0 {
		lowest = 10
	}
	return lowest + 1
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
	g << '\tg_doip.serve.answer = doip_answer'
	g << '\tC.doip_mb_init(&g_doip_req[0], &g_doip_resp[0])'
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
// request waiting in the mailbox, served by the one server.
fn doip_target_serve(m Model) []string {
	if !m.doip.on {
		return []string{}
	}
	return [
		'\t\tif C.doip_mb_take_sent() != 0 {',
		'\t\t\tg_diag.remote_sent()',
		'\t\t}',
		'\t\tif C.doip_mb_take_dropped() != 0 {',
		'\t\t\tg_diag.remote_dropped()',
		'\t\t}',
		'\t\tmut doip_fn := 0',
		'\t\tdoip_n := C.doip_mb_take(&doip_fn)',
		'\t\tif doip_n >= 0 {',
		'\t\t\tdoip_rn := g_diag.serve_remote(&g_doip_req[0], doip_n, doip_fn != 0, &g_doip_resp[0])',
		'\t\t\tC.doip_mb_answer(doip_rn)',
		'\t\t}',
	]
}

// doip_reset_wait: before the MCU resets, the DoIP answers already handed to TCP leave it — bounded,
// as the CAN wait is (a peer that never acknowledges gets the reset all the same)
fn doip_reset_wait(m Model) []string {
	if !m.doip.on {
		return []string{}
	}
	return ['\t\t\tfor C.doip_tx_pending() != 0 && C.board_now_us() - diag_t0 < 500000 {',
		'\t\t\t\tC._tx_thread_sleep(1)', '\t\t\t}']
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
	return 'LOOM_NET_SRCS = ${srcs.join(' ')}\nLOOM_NET_DEFS := -DBLOB_NET_POOL_COUNT=${pool}u\n'
}
