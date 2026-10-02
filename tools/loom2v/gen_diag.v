module main

import toml
import comm.uds

// The diagnostic server's wiring (comm/diag.Connection). What the server does in a pass is the
// module's; what is emitted here is only how an owner configures it and where it calls it — the
// host bus bridge (gen_com.v) and the ThreadX comm thread (below). Both configure it through
// conn_init_lines, so the service table, and what this build performs, is one answer for both.

// UdsCfg is [uds]: the node's ONE ISO 14229 server, whichever transport carries a request to it
// ([isotp] on CAN, and [doip] on a ThreadX target).
struct UdsCfg {
mut:
	on    bool // [uds] declared
	s3_ms int  // 0 = the server's default (5 s)
	// 0x27: failed keys before the lockout, and the lockout delay (0 = the server's defaults)
	security_attempts int
	security_delay_ms int
	// the 0x27 key on a target: 'reference' = blobly_net's public bench key, opted into by name;
	// '' = the OEM's diag_sa_key_ok, which the node's glue must supply (no default is linked)
	security_key string
	// `services` declared: the server answers exactly `services`. Absent = the default table —
	// every service this build performs (diag_unbuilt), in its default sessions.
	table    bool
	services []SvcCfg
}

// SvcCfg is one [uds] `services` row (a comm/uds Service).
struct SvcCfg {
	sid      u8
	sessions u8 // uds.in_* mask; 0 = the service's default sessions (uds.default_sessions)
	security u8 // the 0x27 level the service needs; 0 = none
}

fn parse_uds(doc toml.Doc) UdsCfg {
	uv := doc.value_opt('uds') or { return UdsCfg{} }
	um := uv.as_map()
	mut c := UdsCfg{
		on:                true
		s3_ms:             int((um['s3_ms'] or { toml.Any(0) }).int())
		security_attempts: int((um['security_attempts'] or { toml.Any(0) }).int())
		security_delay_ms: int((um['security_delay_ms'] or { toml.Any(0) }).int())
		security_key:      (um['security_key'] or { toml.Any('') }).string()
		table:             'services' in um
	}
	if c.s3_ms < 0 {
		panic('loom2v: [uds] s3_ms ${c.s3_ms} is negative (0 = the default ${uds.default_s3_us / 1000} ms)')
	}
	if c.security_attempts < 0 || c.security_attempts > 255 {
		panic('loom2v: [uds] security_attempts ${c.security_attempts} is out of range (1..255; 0 = the default ${uds.default_sa_attempts})')
	}
	if c.security_key !in ['', 'reference'] {
		panic('loom2v: [uds] security_key "${c.security_key}" — the one named key is "reference" (blobly_net\'s bench key); leave it out for the OEM\'s diag_sa_key_ok')
	}
	if c.security_delay_ms < 0 {
		panic('loom2v: [uds] security_delay_ms ${c.security_delay_ms} is negative (0 = the default ${uds.default_sa_delay_us / 1000} ms)')
	}
	if !c.table {
		return c
	}
	mut seen := map[u8]string{}
	rows := (um['services'] or { toml.Any(map[string]toml.Any{}) }).as_map()
	// SID order, so the generated table does not depend on how the file spelled it
	mut keys := rows.keys()
	keys.sort_with_compare(fn (a &string, b &string) int {
		return int(parse_sid(*a)) - int(parse_sid(*b))
	})
	for key in keys {
		sid := parse_sid(key)
		if prev := seen[sid] {
			panic('loom2v: [uds] services "${key}" and "${prev}" are one service, 0x${sid.hex()}')
		}
		seen[sid] = key
		rm := (rows[key] or { toml.Any(map[string]toml.Any{}) }).as_map()
		for rk, _ in rm {
			if rk !in ['sessions', 'security'] {
				panic('loom2v: [uds] services 0x${sid.hex()} has "${rk}" — a row takes `sessions` and `security`')
			}
		}
		mut mask := u8(0)
		for sv in (rm['sessions'] or { toml.Any([]toml.Any{}) }).array() {
			mask |= session_bit(sv.string()) or {
				panic('loom2v: [uds] services 0x${sid.hex()} sessions ${err}')
			}
		}
		if 'sessions' in rm && mask == 0 {
			panic('loom2v: [uds] services 0x${sid.hex()} sessions is empty — omit it for the service\'s default sessions')
		}
		sec := (rm['security'] or { toml.Any(0) }).int()
		if sec < 0 || sec > uds.max_security_level {
			panic('loom2v: [uds] services 0x${sid.hex()} security ${sec} is not a 0x27 level (1..${uds.max_security_level})')
		}
		c.services << SvcCfg{
			sid:      sid
			sessions: mask
			security: u8(sec)
		}
	}
	if c.services.len == 0 {
		panic('loom2v: [uds] services is empty — a server answering nothing is no server; omit `services` for the default table')
	}
	if c.services.len > uds.max_services {
		panic('loom2v: [uds] services lists ${c.services.len} — a server table holds at most ${uds.max_services} (comm/uds max_services)')
	}
	return c
}

// parse_sid: a `services` key, the SID in hex ("0x22").
fn parse_sid(key string) u8 {
	h := key.to_lower()
	if !h.starts_with('0x') || h.len < 3 || h.len > 4 || !h[2..].bytes().all(it.is_hex_digit()) {
		panic('loom2v: [uds] services key "${key}" is not a service id — write the SID in hex, e.g. "0x22"')
	}
	return u8(h[2..].parse_uint(16, 8) or { 0 })
}

// diag_unbuilt: why THIS build cannot perform service `sid` ('' = it can). The one statement of
// what each owner wires — conn_init_lines wires 0x11 / 0x28 from it, and validate_uds refuses a
// table row it names — so a configured table can never claim a service that does nothing.
fn diag_unbuilt(m Model, sid u8) string {
	return match sid {
		0x10, 0x22, 0x2E, 0x3E {
			''
		}
		0x11 {
			'' // both owners perform the reset once the answer is out (housekeep / diag_target_reset)
		}
		0x28 {
			if m.target.on {
				'nothing on the target gates its frames on CommunicationControl yet'
			} else {
				''
			}
		}
		0x14, 0x19, 0x85 {
			if m.faults.len == 0 { 'the node has no fault memory (no [[fault]])' } else { '' }
		}
		0x27 {
			if sa_levels(m) == 0 {
				'no [[did]] gate or service row names a security level, so there is nothing to unlock'
			} else {
				''
			}
		}
		else {
			'comm/uds does not implement it'
		}
	}
}

// sa_levels: the 0x27 levels the server serves — every level a [[did]] gate or a service row
// names (bit L-1 for level L). A level nothing is gated on is not offered: unlocking it opens nothing.
fn sa_levels(m Model) u8 {
	mut mask := security_levels(m.dids)
	for r in m.uds.services {
		if r.security != 0 {
			mask |= u8(1) << (r.security - 1)
		}
	}
	return mask
}

// svc_listed: the server answers `sid` if this build performs it — the default table answers
// everything built
fn svc_listed(m Model, sid u8) bool {
	return !m.uds.table || m.uds.services.any(it.sid == sid)
}

// validate_uds refuses a [uds] whose table this build cannot honour, and server settings that
// mean nothing.
fn validate_uds(m Model) {
	if m.isotp_conns.len == 0 {
		if m.uds.on {
			panic('loom2v: [uds] is the diagnostic server, but nothing carries a request to it — declare its [isotp] connection')
		}
		return
	}
	u := m.uds
	// the 0x27 settings mean something only where a gate names a level (sa_levels)
	if sa_levels(m) == 0 && (u.security_attempts != 0 || u.security_delay_ms != 0 || u.security_key != '') {
		panic('loom2v: [uds] configures security_attempts / security_delay_ms / security_key, but no [[did]] gate or service row names a security level — there is nothing to unlock')
	}
	if !u.table {
		return
	}
	for r in u.services {
		h := '0x${r.sid.hex()}'
		why := diag_unbuilt(m, r.sid)
		if why != '' {
			panic('loom2v: [uds] services ${h}: this build cannot perform it — ${why}')
		}
		if r.sessions & uds.in_programming != 0 {
			panic('loom2v: [uds] services ${h} names the programming session — an application server refuses it (programming is the bootloader\'s)')
		}
		if uds.default_sessions(r.sid) != 0 && r.sessions & uds.in_default != 0 {
			panic('loom2v: [uds] services ${h} names the default session, but ISO 14229-1 runs it only in a non-default one')
		}
		if r.sid == 0x10 && r.sessions != 0 && r.sessions & uds.in_default == 0 {
			panic('loom2v: [uds] services 0x10 leaves out the default session — no other session could ever be entered')
		}
		mask := if r.sessions != 0 { r.sessions } else { uds.default_sessions(r.sid) }
		if !svc_listed(m, 0x10) && mask != 0 && mask & uds.in_default == 0 {
			panic('loom2v: [uds] services ${h} runs only outside the default session, but the table leaves out 0x10 — it could never be reached')
		}
		// 0x27 unlocks in extended (an application refuses programming) and every session entry
		// relocks: a 0x27 kept out of extended unlocks nothing any gate (always extended) can use
		if r.sid == 0x27 && mask & uds.in_extended == 0 {
			panic('loom2v: [uds] services 0x27 leaves out the extended session — an unlock elsewhere is relocked by the session change every gate needs')
		}
		if r.security == 0 {
			continue
		}
		if r.sid in [u8(0x10), 0x27, 0x3E] {
			panic('loom2v: [uds] services ${h} cannot need a security level — it is how a tester reaches, unlocks or keeps the session')
		}
		if mask != 0 && mask & uds.in_extended == 0 {
			panic('loom2v: [uds] services ${h} needs security ${r.security} but is not allowed in the extended session, the only one an application server unlocks in — it could never be opened')
		}
	}
	// what the table leaves out must not strand what the rest of the config declares
	if sa_levels(m) != 0 && !svc_listed(m, 0x27) {
		panic('loom2v: [uds] services leaves out 0x27, but a [[did]] gate or service row needs a security level — nothing could unlock it')
	}
	// a DID is reached through its service's row too: both gates must be satisfiable at once —
	// a session they share, and one level (0x27 unlocks exactly one, and both compare exactly)
	for d in m.dids {
		for acc in [
			DidAccess{'read', 0x22, true, d.read_sessions, d.read_security},
			DidAccess{'write', 0x2E, d.writable, d.write_sessions, d.write_security},
		] {
			if !acc.used {
				continue
			}
			row, listed := svc_row(m, acc.sid)
			if !listed {
				panic('loom2v: [[did]] 0x${d.id.hex()}: [uds] services leaves out 0x${acc.sid.hex()} — nothing could ${acc.what} it')
			}
			if row.sessions != 0 && acc.sessions != 0 && row.sessions & acc.sessions == 0 {
				panic('loom2v: [[did]] 0x${d.id.hex()} ${acc.what} gate shares no session with [uds] services 0x${acc.sid.hex()} — it could never be reached')
			}
			if row.security != 0 && acc.security != 0 && row.security != acc.security {
				panic('loom2v: [[did]] 0x${d.id.hex()} ${acc.what} needs security ${acc.security}, but [uds] services 0x${acc.sid.hex()} needs ${row.security} — one unlock cannot satisfy both')
			}
		}
	}
}

// DidAccess is one [[did]] access (read / write) as the service that carries it sees it
struct DidAccess {
	what     string
	sid      u8
	used     bool
	sessions u8
	security u8
}

// svc_row: the table's row for `sid`, its sessions resolved to the service's default when it
// names none — false when a configured table leaves it out (the default table lists everything)
fn svc_row(m Model, sid u8) (SvcCfg, bool) {
	if !m.uds.table {
		return SvcCfg{
			sid:      sid
			sessions: uds.default_sessions(sid)
		}, true
	}
	for r in m.uds.services {
		if r.sid == sid {
			return SvcCfg{
				sid:      sid
				sessions: if r.sessions != 0 { r.sessions } else { uds.default_sessions(sid) }
				security: r.security
			}, true
		}
	}
	return SvcCfg{}, false
}

// conn_init_lines configures connection `c` held at `conn` (e.g. `st.conn_diag`, `g_diag`): the
// link, the default session, the services this build performs (diag_unbuilt) and the table that
// narrows them, and the DID table.
fn conn_init_lines(m Model, c IsotpConn, conn string) []string {
	srv := '${conn}.server'
	mut g := []string{}
	g << '\t${conn}.init(u32(0x${c.rx_id.hex()}), u32(0x${c.tx_id.hex()}), u32(0x${c.functional_id.hex()}), ${c.bs}, ${c.stmin})'
	g << '\t${srv}.no_programming = true // programming is the bootloader\'s (handoff: R2)'
	if m.uds.s3_ms > 0 {
		g << '\t${srv}.s3_us = u64(${m.uds.s3_ms}) * 1000'
	}
	if diag_unbuilt(m, 0x11) == '' {
		g << '\t${srv}.serves_reset = true // the owner performs reset_req once answered'
	}
	if diag_unbuilt(m, 0x28) == '' {
		g << '\t${srv}.serves_comm_control = true // and gates its frames on 0x28'
		if m.buses.len == 1 {
			g << '\t${srv}.single_network = true // 0x28 "all networks" = this one'
		}
	}
	for i, r in m.uds.services {
		mut f := ['sid: 0x${r.sid.hex()}']
		if r.sessions != 0 {
			f << 'sessions: 0x${r.sessions.hex()}'
		}
		if r.security != 0 {
			f << 'security: ${r.security}'
		}
		g << '\t${srv}.services[${i}] = uds.Service{${f.join(', ')}}'
	}
	if m.uds.table {
		g << '\t${srv}.nservices = ${m.uds.services.len} // [uds] services: exactly these'
	}
	for idx, did in m.dids {
		g << '\t${srv}.dids[${idx}] = uds.Did{'
		g << '\t\tid: u16(0x${did.id.hex()})'
		if did.writable {
			g << '\t\twritable: true'
		}
		if did.read_sessions != 0 {
			g << '\t\tread_sessions: u8(0x${did.read_sessions.hex()})'
		}
		if did.write_sessions != 0 {
			g << '\t\twrite_sessions: u8(0x${did.write_sessions.hex()})'
		}
		if did.read_security != 0 {
			g << '\t\tread_security: u8(${did.read_security})'
		}
		if did.write_security != 0 {
			g << '\t\twrite_security: u8(${did.write_security})'
		}
		g << '\t}'
		for bi, b in did.bytes {
			g << '\t${srv}.dids[${idx}].data[${bi}] = u8(0x${b.hex()})'
		}
		if did.bytes.len > 0 {
			g << '\t${srv}.dids[${idx}].len = ${did.bytes.len}'
		}
	}
	g << '\t${srv}.ndid = ${m.dids.len}'
	return g
}

// validate_diag_threadx refuses, on a ThreadX image, what the target comm thread does not serve
// yet — rather than generate a server that answers for something nothing performs.
fn validate_diag_threadx(m Model) {
	for c in m.isotp_conns {
		if c.bus != m.telem.bus {
			panic('loom2v: [target] kind="threadx": [isotp] is on bus "${c.bus}", but the ' +
				'comm thread owns only [telemetry].bus "${m.telem.bus}" — put the connection there')
		}
	}
}

// validate_diag_live_dids: on the target a live DID reads what the node TRANSMITS from a local
// FB — the cells the comm thread already reads (`tx_cells`, recorded where they are allocated, so
// this is that rule and not a second copy of it). A cell has ONE reader (its slot is reader-private,
// boards/common/ioc.h): an input's cell is read by the FB it feeds, and an eth or satellite signal
// has no cell on this thread.
fn validate_diag_live_dids(m Model, tx_cells map[string]bool) {
	for d in m.dids {
		if d.signal == '' {
			continue
		}
		if d.signal !in tx_cells {
			panic('loom2v: [target] kind="threadx": [[did]] 0x${d.id.hex()} reads signal "${d.signal}", ' +
				'but on the target a live DID reads only what this node TRANSMITS on CAN from a local FB ' +
				'(its IOC cell is the comm thread\'s to read; an input\'s cell is its FB\'s, and a cell has one reader)')
		}
		// the cell carries one 32-bit word (the lean encode's), so a wider value has no home in it
		vt := (m.sig_of[d.signal] or { SigInfo{} }).val_type
		if (did_value_width(vt) or { 0 }) > 4 {
			panic('loom2v: [target] kind="threadx": [[did]] 0x${d.id.hex()} reads "${d.signal}", a ${vt}, but ' +
				'its IOC cell on the target carries 32 bits — a live DID there is at most 32 bits wide')
		}
	}
}

// diag_target_fns: the live-DID refresh the connection calls before every dispatch — each
// signal-backed DID takes its cell's current value, the value the comm thread transmits (zero until
// the FB first publishes, as on the bus).
fn diag_target_fns(m Model, ioc_idx map[string]int) []string {
	if m.isotp_conns.len == 0 || !m.dids.any(it.signal != '') {
		return []string{}
	}
	mut g := ['', 'fn diag_refresh_${snake(m.isotp_conns[0].name)}(mut srv uds.Server) {']
	for idx, did in m.dids {
		if did.signal == '' {
			continue
		}
		si := m.sig_of[did.signal] or { panic('loom2v: [[did]] 0x${did.id.hex()}: no signal "${did.signal}"') }
		cell := ioc_idx[did.signal] or {
			panic('loom2v: [[did]] 0x${did.id.hex()}: signal "${did.signal}" has no IOC cell on the comm thread')
		}
		v := 'v_${idx}'
		g << '\tmut ${v} := u32(0)'
		g << '\tmut ${v}_b := u32(0)'
		g << '\tC.ioc_get(${cell}, &${v}, &${v}_b) // ${did.signal}'
		g << did_encode_lines(idx, if si.val_type == 'bool' { '${v} != 0' } else { v }, si.val_type, '\t')
	}
	g << '}'
	return g
}

// did_encode_lines: a live value `expr` into DID `idx` of the server `srv` in a refresh fn — the
// one encode both owners' refreshes emit.
fn did_encode_lines(idx int, expr string, val_type string, ind string) []string {
	return did_signal_encode('srv', idx, expr, val_type).split('\n').map(ind + it.trim_left('\t'))
}

// security_init_lines: 0x27 on `srv`, serving exactly the levels a gate names (sa_levels), with the
// server's attempt limit and lockout delay — every owner's; only the key seam differs
// (`ops`: the host's reference key object, the target's board C seam).
fn security_init_lines(m Model, srv string, ops string) []string {
	levels := sa_levels(m) // validate_uds vetted the settings
	if levels == 0 {
		return []string{}
	}
	mut g := ['\t${srv}.security = ${ops}', '\t${srv}.security_levels = u8(0x${levels.hex()})']
	if m.uds.security_attempts != 0 {
		g << '\t${srv}.sa_attempts = u8(${m.uds.security_attempts})'
	}
	if m.uds.security_delay_ms != 0 {
		g << '\t${srv}.sa_delay_us = u64(${m.uds.security_delay_ms}) * 1000'
	}
	return g
}

// diag_target_sa_fns: the target's 0x27 seam (boards/common/diag_board.c). The seed is the board's
// TRNG (weak, replaceable); the key check is the OEM's `diag_sa_key_ok`, which has NO default —
// a node that gates on a level and forgets it fails to link, naming the symbol — unless the server
// opts into blobly_net's public reference key by name ([uds] security_key), which is then V's own (comm/uds).
fn diag_target_sa_fns(m Model) []string {
	if m.isotp_conns.len == 0 || sa_levels(m) == 0 {
		return []string{}
	}
	mut g := [
		'',
		'fn C.diag_sa_init() int',
		'fn C.diag_sa_seed(&u8, int) int',
		'',
		'fn diag_sa_seed_v(ctx voidptr, out &u8, n int) bool {',
		'\treturn C.diag_sa_seed(out, n) != 0',
		'}',
	]
	if m.uds.security_key != 'reference' {
		g << ''
		g << 'fn C.diag_sa_key_ok(u8, &u8, &u8, int) int'
		g << ''
		g << 'fn diag_sa_key_v(ctx voidptr, level u8, seed &u8, key &u8, n int) bool {'
		g << '\treturn C.diag_sa_key_ok(level, seed, key, n) != 0'
		g << '}'
	}
	return g
}

// diag_target_reset: an answered ECUReset, performed — once the answer is not only out of the link
// but on the wire (the controller's Tx FIFO empty, bounded so a dead bus cannot hold the reset
// off: REQ-BOOT-012), with the 0x27 failed-key counts kept across it.
fn diag_target_reset(m Model, ioc_idx map[string]int) []string {
	if m.isotp_conns.len == 0 {
		return []string{}
	}
	mut g := [
		'\t\tif g_diag.reset_due() != 0 {',
		'\t\t\tdiag_t0 := C.board_now_us()',
		'\t\t\tfor !ch.tx_idle() && C.board_now_us() - diag_t0 < 20000 {}',
	]
	g << doip_reset_wait(m)
	if nvm_on(m) {
		// an orderly shutdown, as a sleep edge is: every persisted value durable and the journal
		// marked clean — a tester's reset must not cost calibration the way a power cut would. A
		// flush or marker that fails holds the reset and retries on the following passes; past the
		// bound the reset goes ahead (its answer promised one), leaving the journal exactly as a
		// power cut would — which it is built to survive.
		g << nvm_flush_choreo(m, ioc_idx, '\t\t\t')
		g << '\t\t\tif !nvm_flush_ok && diag_reset_tries < 20 {'
		g << '\t\t\t\tdiag_reset_tries++'
		g << '\t\t\t\tcontinue'
		g << '\t\t\t}'
	}
	if sa_levels(m) != 0 {
		g << '\t\t\tdiag_keep_now := g_diag.server.kept_security()'
		g << '\t\t\tC.diag_keep_save(&diag_keep_now[0], uds.kept_len)'
	}
	g << '\t\t\tC.diag_sys_reset()'
	g << '\t\t}'
	return g
}

// diag_target_c_decls: the board's reset and keep cell (boards/common/diag_board.c).
fn diag_target_c_decls(m Model) []string {
	if m.isotp_conns.len == 0 {
		return []string{}
	}
	mut g := ['', 'fn C.diag_sys_reset()']
	if sa_levels(m) != 0 {
		g << 'fn C.diag_keep_save(&u8, int)'
		g << 'fn C.diag_keep_load(&u8, int) int'
	}
	return g
}

// diag_target_globals: the connection lives in __global (its link and buffers are ~2 KB — too
// much for the comm thread's stack), bss-zero until diag_target_init.
fn diag_target_globals(m Model) []string {
	if m.isotp_conns.len == 0 {
		return []string{}
	}
	return ['\tg_diag diag.Connection // the diagnostic server on its ISO-TP connection (bss)']
}

// diag_target_init: configured before the loop. ECUReset is served and performed by the comm
// thread (diag_target_reset); CommunicationControl stays unserved (diag_unbuilt): nothing on the
// target gates its frames on it yet. The 0x27 failed-key counts a previous ECUReset kept are
// restored, and a non-zero count arms the lockout delay from boot — a reset between guesses buys
// nothing.
fn diag_target_init(m Model) []string {
	if m.isotp_conns.len == 0 {
		return []string{}
	}
	mut g := conn_init_lines(m, m.isotp_conns[0], 'g_diag')
	g << '\tg_diag.owner_resets = true // the comm thread restarts the MCU (diag_target_reset)'
	if nvm_on(m) {
		g << '\tmut diag_reset_tries := 0 // passes a failed NvM flush has held a due reset'
	}
	if m.dids.any(it.signal != '') {
		g << '\tg_diag.refresh = diag_refresh_${snake(m.isotp_conns[0].name)}'
	}
	if sa_levels(m) != 0 {
		key := if m.uds.security_key == 'reference' { 'uds.reference_key_ok' } else { 'diag_sa_key_v' }
		// the RNG's clock is set up here, once, before the loop — never inside a request
		g << '\tC.diag_sa_init() // 0 = no RNG: every seed request is then refused'
		g << security_init_lines(m, 'g_diag.server', 'uds.SecurityOps{\n\t\tseed:   diag_sa_seed_v\n\t\tkey_ok: ${key}\n\t}')
		g << '\tmut diag_kept := [uds.kept_len]u8{}'
		g << '\tif C.diag_keep_load(&diag_kept[0], uds.kept_len) != 0 {'
		g << '\t\tg_diag.server.restore_security(diag_kept) // a lockout or a count runs on from boot'
		g << '\t}'
	}
	g << '\tmut diag_txf := can.Frame{}'
	return g
}

// diag_target_housekeep: the top of every pass, before the drain.
fn diag_target_housekeep(m Model) []string {
	if m.isotp_conns.len == 0 {
		return []string{}
	}
	return ['\t\tg_diag.housekeep(C.board_now_us())']
}

// diag_target_rx_arm: the connection's share of the drain. With no 0x28 on the target a request
// gates nothing behind it, so it is served where it completes and the drain goes on — frames the
// gateway forwards are not held a pass for a diagnostic request. In bus sleep nothing reaches the
// server: it could not answer; once served, a request holds the network up (diag_target_nm_hold).
fn diag_target_rx_arm(m Model) []string {
	if m.isotp_conns.len == 0 {
		return []string{}
	}
	awake := if m.nm.on { 'g_nm.awake() && ' } else { '' }
	return [
		'\t\t\tif ${awake}g_diag.on_frame(C.board_now_us(), &rx) == .request {',
		'\t\t\t\tg_diag.serve()',
		'\t\t\t}',
	]
}

// diag_target_nm_hold: before the NM tick, so a request served this pass keeps the network up
// before NM can decide to sleep — including out of prepare_bus_sleep.
fn diag_target_nm_hold(m Model) []string {
	if m.isotp_conns.len == 0 || !m.nm.on {
		return []string{}
	}
	return ['\t\tg_nm.hold(t1, g_diag.active()) // a diagnostic exchange or session keeps the bus up']
}

// diag_target_produce: the answer in flight, tx_ready-gated like every producer, and ahead of all of
// them (telemetry, COM, trace, shell) — an answer is a few frames a tester is timing, and a Tx FIFO
// kept full by periodic traffic must not strand it. A frame
// the channel refuses aborts the transfer; the tester retries. NM cannot sleep under it: the
// connection holds the network while active (diag_target_nm_hold).
fn diag_target_produce(m Model) []string {
	if m.isotp_conns.len == 0 {
		return []string{}
	}
	return [
		'\t\tfor ${nm_gate(m)}ch.tx_ready() && g_diag.produce(t1, mut diag_txf) {',
		'\t\t\tif !ch.send(diag_txf) {',
		'\t\t\t\tg_diag.abort_tx()',
		'\t\t\t\tbreak',
		'\t\t\t}',
		'\t\t}',
	]
}
