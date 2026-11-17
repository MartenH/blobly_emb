module main

import os

// The diagnostic half of a generated bridge pass must run in ONE order, and review found the
// same seam three times running (a pending reset vs. the next request; a request vs. the frames
// queued behind it). This pins the order in the committed generated glue of examples/overspeed —
// which CI's "Generated outputs are fresh" gate keeps identical to what loom2v emits today:
//
//   housekeeping (ISO-TP timeouts expired → a pending reset applied → S3 held while the link is
//   busy → S3 checked) → receive gate sampled → rx drain, stopping at a request that completes
//   during it → one request served (one that completes while a response is still in
//   flight is dropped — half-duplex, the tester retries) →
//   response transmitted → the rx gate re-sampled and the rx deadlines checked (after the pass's
//   requests, so a 0x28 suspends them first) → the 0x28 tx gate sampled → application tx, a value
//   under 0x2F control written over the FB's before the encode. A functional request is served
//   ON ARRIVAL inside the drain (quiet link, no reset pending) and re-samples the rx gate at once.
fn test_the_generated_diagnostic_pass_runs_in_order() {
	glue := os.read_file(os.join_path(@VMODROOT, 'examples', 'overspeed', 'gen', 'loom_gen.v')) or {
		assert false, '${err}'
		return
	}
	// the connection's own steps (housekeeping, one request at a time, the drop while busy) are
	// comm/diag's and tested there; this pins where the bridge calls them
	steps := [
		// a routine's result read BEFORE the housekeeping, whose tick judges the routine's deadline:
		// a result the FB published before it counts (comm/uds pending.v, gen_routine.v)
		'osal.ioc_acquire(routine_res_self_check_ch, &st.conn_diag.server.routines[0].res',
		'st.conn_diag.housekeep(now)',
		'if st.rxg.sample(st.conn_diag.server.rx_enabled(), true)',
		// the request after the fault pass, before the drain: a request the server wrote last pass,
		// or a stop its housekeeping asked, reaches its FB
		'osal.ioc_publish(fault_ctl_engine_monitor_ch',
		'osal.ioc_publish(routine_req_self_check_ch, &st.conn_diag.server.routines[0].req',
		'for st.chan.recv(mut rx) {',
		'match st.conn_diag.on_frame(now, rx) {',
		'.request { break }',
		'.served {',
		'if st.rxg.sample(st.conn_diag.server.rx_enabled(), true)',
		'st.conn_diag.serve()',
		'st.conn_diag.pump(now, mut st.chan)', // comm/diag's step: a refused frame aborts the answer
		'if st.rxg.sample(st.conn_diag.server.rx_enabled(), true)',
		'if st.rxg.settle()',
		'diag_tx_ok :=',
		'warn_lamp_io_on, warn_lamp_io_v := st.conn_diag.server.io_held(0)', // 0x2F (gen_ioctl.v)
		'warn_lamp.on = warn_lamp_io_v != 0',
		'lamp_frame_warn_lamp_set(mut tx_lamp_frame.data, if warn_lamp.on {',
		'if tx_lamp_frame_any && diag_tx_ok',
	]
	mut at := -1
	for step in steps {
		i := glue[at + 1..].index(step) or {
			assert false, 'step "${step}" missing or out of order (after offset ${at})'
			return
		}
		at = at + 1 + i
	}
}

// a connection with no [[did]] and no [[routine]] names nothing from comm.uds: importing it would
// warn on every build
fn test_the_uds_import_follows_the_dids() {
	mut m := Model{
		isotp_conns: [IsotpConn{
			name: 'diag'
			bus:  'can0'
		}]
	}
	_, bare := emit_module_headers(m, 'ecu', false, false)
	assert 'import comm.diag' in bare
	assert 'import comm.uds' !in bare
	m.dids = [DidCfg{
		id: 0xF190
	}]
	_, with_dids := emit_module_headers(m, 'ecu', false, false)
	assert 'import comm.uds' in with_dids
	m.dids = []
	m.routines = [RoutineCfg{
		name: 'SelfCheck'
		id:   0x0201
	}]
	_, with_routines := emit_module_headers(m, 'ecu', false, false)
	assert 'import comm.uds' in with_routines
}

