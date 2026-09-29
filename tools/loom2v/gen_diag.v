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
	if security_levels(m.dids) != 0 {
		panic('loom2v: [target] kind="threadx": a [[did]] gate names a security level, but 0x27 on the ' +
			'target needs the board key seam — the next R2 step (docs/diagnostics.md)')
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
		if vt in ['u64', 'i64'] {
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
	if m.dids.any(it.signal != '') {
		g << '\tg_diag.refresh = diag_refresh_${snake(m.isotp_conns[0].name)}'
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
