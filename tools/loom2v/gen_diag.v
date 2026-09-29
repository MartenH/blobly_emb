module main

// The diagnostic server's wiring (comm/diag.Connection). What the server does in a pass is the
// module's; what is emitted here is only how an owner configures it and where it calls it — the
// host bus bridge (gen_com.v) and the ThreadX comm thread (below).

// conn_init_lines configures connection `c` held at `conn` (e.g. `st.conn_diag`, `g_diag`): the
// link, the default session, the options every owner sets, and the DID table.
fn conn_init_lines(m Model, c IsotpConn, conn string) []string {
	srv := '${conn}.server'
	mut g := []string{}
	g << '\t${conn}.init(u32(0x${c.rx_id.hex()}), u32(0x${c.tx_id.hex()}), u32(0x${c.functional_id.hex()}), ${c.bs}, ${c.stmin})'
	g << '\t${srv}.no_programming = true // programming is the bootloader\'s (handoff: R2)'
	if c.s3_ms > 0 {
		g << '\t${srv}.s3_us = u64(${c.s3_ms}) * 1000'
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
			panic('loom2v: [target] kind="threadx": [[isotp]] "${c.name}" is on bus "${c.bus}", but the ' +
				'comm thread owns only [telemetry].bus "${m.telem.bus}" — put the connection there')
		}
	}
	for d in m.dids {
		if d.signal != '' {
			panic('loom2v: [target] kind="threadx": [[did]] 0x${d.id.hex()} reads signal "${d.signal}" — ' +
				'live DIDs on the target are the next R2 step (docs/diagnostics.md); use a constant')
		}
	}
	if security_levels(m.dids) != 0 {
		panic('loom2v: [target] kind="threadx": a [[did]] gate names a security level, but 0x27 on the ' +
			'target needs the board key seam — the next R2 step (docs/diagnostics.md)')
	}
}

// diag_target_globals: the connection lives in __global (its link and buffers are ~2 KB — too
// much for the comm thread's stack), bss-zero until diag_target_init.
fn diag_target_globals(m Model) []string {
	if m.isotp_conns.len == 0 {
		return []string{}
	}
	return ['\tg_diag diag.Connection // the diagnostic server on its ISO-TP connection (bss)']
}

// diag_target_init: configured before the loop. ECUReset and CommunicationControl stay
// unserved (serviceNotSupported): nothing on the target performs a reset or gates its frames yet.
fn diag_target_init(m Model) []string {
	if m.isotp_conns.len == 0 {
		return []string{}
	}
	mut g := conn_init_lines(m, m.isotp_conns[0], 'g_diag')
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

// diag_target_produce: the answer in flight, tx_ready-gated like every producer, and ahead of the
// trace and shell streams — an answer is a few frames a tester is timing, a dump is many. A frame
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
