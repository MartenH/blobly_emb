module main

import os

// [doip] (gen_doip.v): the node's one diagnostic server reachable over DoIP too — what the
// generator wires into the comm thread and boot, and what it refuses. Runs the real generator on
// examples/h735_threadx with a connection and [doip] appended (a refusal is a panic, which cannot
// be caught in-process).

const doip_conn = '
[[isotp]]
name          = "diag"
bus           = "can0"
rx_id         = 0x7B0
tx_id         = 0x7B8
functional_id = 0x7DF

[[did]]
id    = 0xF190
ascii = "BLOBLYH735THREADX"

[doip]
address         = "192.168.0.50"
logical_address = 0x07B0
'

fn doip_loom2v() string {
	bin := os.join_path(os.temp_dir(), 'loom2v_doip_target_${os.getpid()}')
	if !os.exists(bin) {
		r := os.execute('${@VEXE} -enable-globals -o ${bin} ${os.join_path(@VMODROOT, 'tools',
			'loom2v')}')
		assert r.exit_code == 0, r.output
	}
	return bin
}

// generate runs loom2v on h735_threadx's config with `extra` appended: exit code, output, glue
fn generate(name string, extra string) (int, string, string) {
	tmp := os.join_path(os.temp_dir(), 'doip_target_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	ex := os.join_path(@VMODROOT, 'examples', 'h735_threadx')
	os.mkdir_all(tmp) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	src := os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) }
	os.write_file(ecu, src + extra) or { panic(err) }
	dbc := os.join_path(tmp, 'bus.dbc')
	os.cp(os.join_path(ex, 'bus.dbc'), dbc) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${doip_loom2v()} ${ecu} ${dbc} ${os.join_path(tmp, 'sig.v')} ' +
		'${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }
}

// generate_ecu runs loom2v on `ecu` alone (h735_threadx's DBC beside it)
fn generate_ecu(name string, ecu_text string) (int, string, string, string) {
	tmp := os.join_path(os.temp_dir(), 'doip_target_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	os.mkdir_all(tmp) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	os.write_file(ecu, ecu_text) or { panic(err) }
	dbc := os.join_path(tmp, 'bus.dbc')
	os.cp(os.join_path(@VMODROOT, 'examples', 'h735_threadx', 'bus.dbc'), dbc) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${doip_loom2v()} ${ecu} ${dbc} ${os.join_path(tmp, 'sig.v')} ' +
		'${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }, os.read_file(os.join_path(tmp,
		'loom_build.mk')) or { '' }
}

fn test_the_comm_thread_serves_doip_from_the_mailbox() {
	code, out, glue := generate('doip_ok', doip_conn)
	assert code == 0, out
	assert glue.contains('import comm.doip')
	for g in ['g_doip      doip.Server', 'g_doip_out  [doip.max_resp]u8', 'g_doip_resp [doip.max_uds]u8'] {
		assert glue.contains(g), g
	}
	// the TCP seed before the loop; each pass: housekeep, what the doip thread reported, then the
	// request in the mailbox — served by the ONE server, ahead of the CAN drain
	steps := [
		'C.doip_net_seed(doip_seed)',
		'g_diag.housekeep(',
		'if C.doip_mb_take_sent() != 0 {',
		'g_diag.remote_sent()',
		'if C.doip_mb_take_dropped() != 0 {',
		'g_diag.remote_dropped()',
		'doip_n := C.doip_mb_take(&doip_fn)',
		'g_diag.serve_remote(&g_doip_req[0], doip_n, doip_fn != 0, &g_doip_resp[0])',
		'C.doip_mb_answer(doip_rn, if g_diag.server.reset_req != 0 { 1 } else { 0 })',
		'for ch.recv(mut rx) {',
	]
	mut at := -1
	for step in steps {
		i := glue[at + 1..].index(step) or {
			assert false, 'step "${step}" missing or out of order (after offset ${at})'
			return
		}
		at = at + 1 + i
	}
	// boot: the identity before any thread runs (DID 0xF190 is the VIN), then NetX; the IP thread
	// at the comm thread's priority, the doip threads just below it
	assert glue.contains('g_doip.entity_addr = u16(0x7b0)')
	assert glue.contains("doip_vin := 'BLOBLYH735THREADX'")
	assert glue.contains('g_doip.serve.answer = doip_answer')
	assert glue.contains("C.doip_net_create(c'192.168.0.50', u32(10), u32(11))") // comm at 10 here
	assert !glue.contains('functional_addr'), 'the default functional address is comm/doip\'s'
	// no 0x27 here: the TRNG seam is declared for the seed alone
	assert glue.contains('fn C.diag_sa_seed(&u8, int) int')
	// trace: the three threads bound in manifest order
	assert glue.contains('C.trace_bind_thread(C.doip_net_tcb(0)) // NetX IP thread')
	assert glue.contains('C.trace_bind_thread(C.doip_net_tcb(2)) // doip-svc')
}

fn test_a_doip_config_that_cannot_be_served_is_refused() {
	cases := {
		'no_server':  doip_conn.all_after('ascii = "BLOBLYH735THREADX"\n')
		'tester_la':  doip_conn.replace('logical_address = 0x07B0', 'logical_address = 0x0E80')
		'bad_ip':     doip_conn.replace('"192.168.0.50"', '"192.168.0"')
		'short_vin':  doip_conn.replace('BLOBLYH735THREADX', 'BLOBLYH735THREAD')
		'func_range': doip_conn + 'functional_address = 0x1234\n'
		// REQ-NET-012: a write reachable over IP needs a security level
		'open_write': doip_conn.replace('[doip]', '[[did]]\nid    = 0x0102\nbytes = "00"\nwrite = { session = ["extended"] }\n\n[doip]')
	}
	for name, extra in cases {
		code, out, _ := generate('doip_${name}', extra)
		assert code != 0, 'loom2v accepted [doip] case ${name}'
		assert out.contains('[doip]'), '${name}: ${out}'
	}
	// gated, the same write is accepted
	gated := doip_conn.replace('[doip]', '[[did]]\nid    = 0x0102\nbytes = "00"\nwrite = { session = ["extended"], security = 1 }\n\n[doip]')
	code, out, _ := generate('doip_gated', gated)
	assert code == 0, out
}

fn test_ip4_ok_is_the_drivers_rule() {
	for good in ['192.168.0.50', '10.0.0.2', '255.255.255.254'] {
		assert ip4_ok(good), good
	}
	for bad in ['192.168.0', '192.168..50', '192.168.0.', '256.1.1.1', '1.2.3.4.5', 'a.b.c.d', '1.2.3.0050', '0.0.0.0', '192.168.0.1', '192.168.0.255'] {
		assert !ip4_ok(bad), bad
	}
}

// the trace recorder binds 8 thread ids: h735_threadx with DoIP fills them exactly (comm, three
// app threads, NetX IP, doip, doip-svc, the timer); one thread more is refused, not mislabelled
fn test_a_trace_past_the_recorders_thread_table_is_refused() {
	src := os.read_file(os.join_path(@VMODROOT, 'examples', 'h735_threadx', 'ecu.toml')) or { panic(err) }
	at := src.index('  [[partition.thread]]') or { panic('no thread in h735_threadx') }
	more := src[..at] + '  [[partition.thread]]\n  name     = "extra"\n  priority = 14\n\n' + src[at..]
	code, out, _, _ := generate_ecu('doip_trace_full', more + doip_conn)
	assert code != 0, 'loom2v accepted 9 traced threads'
	assert out.contains('MAX_THREADS'), out
}
