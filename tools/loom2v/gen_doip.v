module main

import toml

// [doip]: the node's ONE diagnostic server — the [[isotp]] connection's — reachable over DoIP
// (ISO 13400) too, on a ThreadX target. The server stays on the comm thread; a doip thread
// (driver/eth/doip_netx.c) runs the TCP side and hands each request across a mailbox, so CAN and
// DoIP testers share one session; a 0x27 unlock is per transport (comm/diag serve_remote).
struct DoipCfg {
	on         bool
	address    string // the node's static IPv4 address
	logical    int    // its DoIP logical address
	functional int    // 0 = comm/doip's default (0xE400)
}

const doip_vin_did = 0xF190

fn parse_doip(doc toml.Doc) DoipCfg {
	dv := doc.value_opt('doip') or { return DoipCfg{} }
	dm := dv.as_map()
	return DoipCfg{
		on:         true
		address:    (dm['address'] or { toml.Any('') }).string()
		logical:    int((dm['logical_address'] or { toml.Any(0) }).int())
		functional: int((dm['functional_address'] or { toml.Any(0) }).int())
	}
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
		panic('loom2v: [doip] carries the node\'s ONE diagnostic server — declare its [[isotp]] connection')
	}
	if m.eth != '' {
		panic('loom2v: [doip] with eth bus "${m.eth}": one NetX instance per image, and driver/eth/eth_netx.c already owns it')
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
	// REQ-NET-012: over IP, reachability alone must not grant a write
	for did in m.dids {
		if did.writable && did.write_security == 0 {
			panic('loom2v: [doip] makes DID 0x${did.id.hex()} writable from the network with no security level — ' +
				'gate it (write = { security = N }), REQ-NET-012')
		}
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
		'fn C.doip_net_seed(u32)',
		'fn C.doip_net_tcb(int) voidptr',
		'fn C.doip_mb_init(&u8, &u8)',
		'fn C.doip_mb_call(&u8, int, int, &u8, int) int',
		'fn C.doip_mb_take(&int) int',
		'fn C.doip_mb_answer(int, int)',
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
	if security_levels(m.dids) == 0 {
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
	g << '\tmut eid := [6]u8{}'
	g << '\tC.doip_eid(&eid[0])'
	g << '\tmut ann := [64]u8{}'
	g << '\tan := g_doip.announcement(&eid[0], &ann[0])'
	g << '\tfor _ in 0 .. 3 {'
	g << '\t\tC.doip_udp_broadcast(&ann[0], an)'
	g << '\t\tC.doip_sleep_ms(500)'
	g << '\t}'
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
	g << '\t\t\tC.doip_stream_drop() // stream desynced, NACK already sent'
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
	g << '\tC.doip_stream_notify_activated(0) // the next connection gets the 2 s initial limit'
	g << '}'
	g << ''
	g << '// doip_ident: vehicle identification on UDP 13400 (the doip-svc thread); identity is set at boot'
	g << "@[export: 'blobly_doip_ident']"
	g << 'fn doip_ident(req &u8, n int, resp &u8) int {'
	g << '\tmut eid := [6]u8{}'
	g << '\tC.doip_eid(&eid[0])'
	g << '\treturn g_doip.ident_response(req, n, &eid[0], resp)'
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
	g << '\tg_doip.serve.answer = doip_answer'
	g << '\tC.doip_mb_init(&g_doip_req[0], &g_doip_resp[0])'
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
// numbers from (0 = none: doip_netx.c falls back to the chip id, distinct but not secret).
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
		'\t\t\t// a reset waiting on this answer: the doip thread reports it sent once acknowledged',
		'\t\t\tC.doip_mb_answer(doip_rn, if g_diag.server.reset_req != 0 { 1 } else { 0 })',
		'\t\t}',
	]
}
