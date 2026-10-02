module main

import os

// The diagnostic server on a ThreadX comm thread (docs/diagnostics.md R2): what the generator
// wires, in what order, and what it refuses until the next R2 steps. Runs the real generator on
// examples/h735_threadx (ThreadX, NM, trace and shell on can0, no [nvm]) with a connection added —
// a refusal is a panic, which cannot be caught in-process.

const diag_conn = '
[isotp]
bus           = "can0"
rx_id         = 0x7B0
tx_id         = 0x7B8
functional_id = 0x7DF

[[did]]
id    = 0xF190
ascii = "BLOBLY-TEST"
'

fn loom2v_bin() string {
	bin := os.join_path(os.temp_dir(), 'loom2v_diag_target_${os.getpid()}')
	if !os.exists(bin) {
		r := os.execute('${@VEXE} -enable-globals -o ${bin} ${os.join_path(@VMODROOT, 'tools',
			'loom2v')}')
		assert r.exit_code == 0, r.output
	}
	return bin
}

// generate runs loom2v on h735_threadx's config with `extra` appended; returns the exit code, the
// output and the generated glue.
fn generate(name string, extra string) (int, string, string) {
	return generate_edited(name, fn (src string) string {
		return src
	}, extra)
}

// generate_edited is generate with h735_threadx's config edited first.
fn generate_edited(name string, edit fn (string) string, extra string) (int, string, string) {
	tmp := os.join_path(os.temp_dir(), 'diag_target_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	return run_in_scratch(tmp, 'h735_threadx', edit, extra)
}

// run_in_scratch runs loom2v on a copy of example `name`'s config (edited, `extra` appended) placed
// in a sibling layout under `tmp`, so paths the config resolves against itself stay inside `tmp`.
fn run_in_scratch(tmp string, name string, edit fn (string) string, extra string) (int, string, string) {
	ex := os.join_path(@VMODROOT, 'examples', name)
	scratch_ex := os.join_path(tmp, name)
	os.mkdir_all(scratch_ex) or { panic(err) }
	src := os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) }
	ecu := os.join_path(scratch_ex, 'ecu.toml')
	os.write_file(ecu, edit(src) + extra) or { panic(err) }
	os.cp(os.join_path(ex, 'bus.dbc'), os.join_path(scratch_ex, 'bus.dbc')) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${loom2v_bin()} ${ecu} ${os.join_path(scratch_ex, 'bus.dbc')} ${os.join_path(tmp,
		'sig.v')} ${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }
}

fn test_the_comm_thread_serves_the_connection_in_order() {
	code, out, glue := generate('ok', diag_conn)
	assert code == 0, out
	assert glue.contains('g_diag diag.Connection')
	assert glue.contains('g_comm_stack [8192]u8'), 'the dispatch needs the larger comm stack'
	// init before the loop; housekeep, then the drain's arm; the answer drains ahead of the
	// trace and shell streams; abandoned in NM sleep; a 1-tick wake while it is in flight
	steps := [
		'g_diag.init(u32(0x7b0), u32(0x7b8), u32(0x7df)',
		'mut diag_txf := can.Frame{}',
		'wait_ticks := if g_tm.is_dumping() || g_diag.link.busy() {',
		'g_diag.housekeep(',
		'for ch.recv(mut rx) {',
		'if g_nm.awake() && g_diag.on_frame(',
		'g_diag.serve()',
		'g_nm.hold(t1, g_diag.active())',
		'nm_up := g_nm.awake()',
		'g_diag.produce(t1, mut diag_txf)',
		'if g_diag.reset_due() != 0 {',
		'for !ch.tx_idle() && C.board_now_us() - diag_t0 < 20000 {}',
		'C.diag_sys_reset()',
		'// PRODUCER: CpuLoad telemetry',
		'g_tm.produce(t1, mut trace_txf)',
		'g_sh.produce(t1, mut shell_txf)',
	]
	mut at := -1
	for step in steps {
		i := glue[at + 1..].index(step) or {
			assert false, 'step "${step}" missing or out of order (after offset ${at})'
			return
		}
		at = at + 1 + i
	}
	// the comm thread performs an answered reset; nothing gates its frames on 0x28 yet
	assert glue.contains('g_diag.server.serves_reset = true')
	assert glue.contains('g_diag.owner_resets = true')
	assert !glue.contains('g_diag.server.serves_comm_control = true')
}

// a live DID reads what the node transmits, from the cell the comm thread already reads; an input's
// cell is its FB's (one reader per cell) and an internal signal has no cell on the comm thread
fn test_a_live_did_reads_only_the_nodes_own_outputs() {
	live := '
[[did]]
id     = 0xF1A0
signal = "Workload"
'
	code, out, glue := generate('live', diag_conn + live)
	assert code == 0, out
	assert glue.contains('fn diag_refresh_diag(mut srv uds.Server) {')
	assert glue.contains('g_diag.refresh = diag_refresh_diag')
	assert glue.contains('C.ioc_get(0, &v_1, &v_1_b) // Workload')
	for sig in ['Command', 'LoadCmd'] {
		c2, o2, _ := generate('live_${sig}', diag_conn + live.replace('Workload', sig))
		assert c2 != 0, 'loom2v accepted a live DID on ${sig}'
		assert o2.contains('reads only what this node TRANSMITS'), o2
	}
}

// 0x27 on the target: the levels a DID gate names, the [uds] limits, the board's TRNG seed
// set up once before the loop — and the OEM's key check, with no default linked, unless the
// server opts into blobly_net's reference key by name
fn test_a_security_gate_is_served_through_the_board_seam() {
	gated := '
[[did]]
id    = 0xF1AC
bytes = "00"
write = { session = ["extended"], security = 1 }
'
	limits := '\n[uds]\nsecurity_attempts = 2\nsecurity_delay_ms = 3000'
	code, out, glue := generate('sec', diag_conn + gated + limits)
	assert code == 0, out
	for want in ['fn C.diag_sa_seed(&u8, int) int', 'fn diag_sa_seed_v(ctx voidptr, out &u8, n int) bool {',
		'return C.diag_sa_seed(out, n) != 0', 'fn C.diag_sa_key_ok(u8, &u8, &u8, int) int',
		'return C.diag_sa_key_ok(level, seed, key, n) != 0', 'C.diag_sa_init()',
		'g_diag.server.security = uds.SecurityOps{', 'seed:   diag_sa_seed_v', 'key_ok: diag_sa_key_v',
		'g_diag.server.security_levels = u8(0x01)', 'g_diag.server.sa_attempts = u8(2)',
		'g_diag.server.sa_delay_us = u64(3000) * 1000',
		// the failed-key counts kept across the node's own reset, saved before it
		'if C.diag_keep_load(&diag_kept[0], uds.kept_len) != 0 {',
		'g_diag.server.restore_security(diag_kept)', 'diag_keep_now := g_diag.server.kept_security()',
		'C.diag_keep_save(&diag_keep_now[0], uds.kept_len)'] {
		assert glue.contains(want), 'missing: ${want}'
	}
	// the bench key, by name: V's own, and no C key declared at all
	c2, o2, g2 := generate('sec_ref', diag_conn + gated + limits + '\nsecurity_key = "reference"\n')
	assert c2 == 0, o2
	assert g2.contains('key_ok: uds.reference_key_ok')
	assert !g2.contains('diag_sa_key_ok')
	c3, o3, _ := generate('sec_bad', diag_conn + gated + limits + '\nsecurity_key = "oem"\n')
	assert c3 != 0, 'loom2v accepted an unknown security_key'
	assert o3.contains('the one named key is "reference"'), o3
}

fn test_a_connection_off_the_comm_threads_bus_is_refused() {
	code, out, _ := generate('bus', diag_conn.replace('bus           = "can0"', 'bus           = "can1"') +
		'
[bus.can1]
interface = "vcan1"
')
	assert code != 0, 'loom2v accepted a connection the comm thread does not own'
	assert out.contains('comm thread owns only'), out
}

// the physical ids are matched and sent beside the node's other traffic, like the functional one
fn test_a_diagnostic_id_on_another_frames_id_is_refused() {
	code, out, _ := generate('rx', diag_conn.replace('rx_id         = 0x7B0', 'rx_id         = 0x7E0'))
	assert code != 0, 'loom2v accepted an rx_id on the telemetry id'
	assert out.contains('rx_id 0x7e0 is also a [telemetry] frame id'), out
	code2, out2, _ := generate('tx', diag_conn.replace('tx_id         = 0x7B8', 'tx_id         = 0x7F1'))
	assert code2 != 0, 'loom2v accepted a tx_id on the shell out id'
	assert out2.contains('tx_id 0x7f1 is also a [shell] endpoint id'), out2
}

fn test_a_diagnostic_id_in_the_nm_range_or_wider_than_11_bits_is_refused() {
	code, out, _ := generate('nm', diag_conn.replace('rx_id         = 0x7B0', 'rx_id         = 0x510'))
	assert code != 0, 'loom2v accepted an rx_id in the NM peer range'
	assert out.contains('[nm] peer range'), out
	code2, out2, _ := generate('wide', diag_conn.replace('tx_id         = 0x7B8', 'tx_id         = 0x8100'))
	assert code2 != 0, 'loom2v accepted a 16-bit tx_id'
	assert out2.contains('tx_id 0x8100 must be a standard 11-bit id'), out2
}

// on ThreadX, [nm].bus is a label: NM runs on the comm thread's channel, so that is the bus checked
fn test_the_nm_range_is_checked_on_the_comm_threads_channel() {
	peers := 'peers = [0x500, 0x53F]'
	code, out, _ := generate_edited('nmlabel', fn [peers] (src string) string {
		assert src.contains(peers), 'h735_threadx [nm] changed shape — update this test'
		return src.replace(peers, peers + '\nbus   = "can1"')
	}, diag_conn.replace('rx_id         = 0x7B0', 'rx_id         = 0x510') +
		'\n[bus.can1]\ninterface = "vcan1"\n')
	assert code != 0, 'loom2v accepted an rx_id in the NM range under a [nm].bus label'
	assert out.contains('[nm] peer range'), out
}

// a live DID is written in its value's own width, big-endian — never truncated to a byte
fn test_a_live_did_is_encoded_in_its_values_width() {
	assert did_signal_encode('srv', 2, 'v', 'i32') == '\t\tsrv.dids[2].data[0] = u8(v >> 24)\n' +
		'\t\tsrv.dids[2].data[1] = u8(v >> 16)\n\t\tsrv.dids[2].data[2] = u8(v >> 8)\n' +
		'\t\tsrv.dids[2].data[3] = u8(v)\n\t\tsrv.dids[2].len = 4'
	assert did_signal_encode('srv', 0, 'v', 'i16').ends_with('.len = 2')
	assert did_signal_encode('srv', 0, 'v', 'u64').ends_with('.len = 8')
	assert did_signal_encode('srv', 0, 'v', 'u8').ends_with('.len = 1')
}

// a target cell carries one 32-bit word, so a wider output cannot be a live DID there
fn test_a_live_did_wider_than_the_cell_is_refused() {
	field := 'fields = { v = "u32" }'
	code, out, _ := generate_edited('wide_did', fn [field] (src string) string {
		assert src.contains(field), 'h735_threadx Workload changed shape — update this test'
		return src.replace(field, 'fields = { v = "u64" }')
	}, diag_conn + '
[[did]]
id     = 0xF1A0
signal = "Workload"
')
	assert code != 0, 'loom2v accepted a 64-bit live DID on the target'
	assert out.contains('at most 32 bits wide'), out
}

// a live DID is read-only, and carries an integer or a bool — refused at validation, for every owner
fn test_a_live_did_that_cannot_be_one_is_refused() {
	code, out, _ := generate('live_w', diag_conn + '
[[did]]
id       = 0xF1A0
signal   = "Workload"
writable = true
')
	assert code != 0, 'loom2v accepted a writable live DID'
	assert out.contains('a live DID is read-only'), out
	field := 'fields = { v = "u32" }'
	code2, out2, _ := generate_edited('live_f', fn [field] (src string) string {
		return src.replace(field, 'fields = { v = "f32" }')
	}, diag_conn + '
[[did]]
id     = 0xF1A0
signal = "Workload"
')
	assert code2 != 0, 'loom2v accepted a float live DID'
	assert out2.contains('carries an integer or a bool'), out2
	assert did_value_width('f32') == none
	assert did_value_width('i32') or { 0 } == 4
}

// on a node with [nvm], the reset is an orderly shutdown: the journal flushed and marked clean
// first, and a failing flush holds the reset for a bounded number of passes
fn test_the_reset_flushes_the_journal_first() {
	src := os.read_file(os.join_path(@VMODROOT, 'examples', 'h755_threadx', 'ecu.toml')) or { panic(err) }
	assert src.contains('[nvm]'), 'h755_threadx lost its [nvm] — update this test'
	tmp := os.join_path(os.temp_dir(), 'diag_target_nvm_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	// the satellite partition's `image = "../h755_m4_app"` resolves into the scratch layout
	code, out, g := run_in_scratch(tmp, 'h755_threadx', fn (s string) string {
		return s
	}, diag_conn)
	assert code == 0, out
	assert os.exists(os.join_path(tmp, 'h755_m4_app', 'gen')), 'the satellite image was not generated into the scratch layout'
	steps := ['if g_diag.reset_due() != 0 {', 'for !ch.tx_idle()', 'nvm_flush_ok = g_nvm.mark_clean()',
		'if !nvm_flush_ok && diag_reset_tries < 20 {', 'C.diag_sys_reset()']
	mut at := -1
	for step in steps {
		i := g[at + 1..].index(step) or {
			assert false, 'step "${step}" missing or out of order'
			return
		}
		at = at + 1 + i
	}
}

// generate_host runs loom2v on the HOST example overspeed (a bus bridge owns the server, with a
// fault memory and a DID gated on security level 1), its config edited and `extra` appended.
fn generate_host(name string, edit fn (string) string, extra string) (int, string, string) {
	tmp := os.join_path(os.temp_dir(), 'diag_host_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	return run_in_scratch(tmp, 'overspeed', edit, extra)
}

fn same(src string) string {
	return src
}

// No `services`: the default table — nothing emitted, so the server keeps the behaviour it had
// before the table existed (comm/uds test_the_default_table_is_the_old_behaviour), on both owners.
fn test_no_service_table_is_the_default_set() {
	code, out, glue := generate('default_table', diag_conn)
	assert code == 0, out
	assert !glue.contains('.services[') && !glue.contains('.nservices'), glue
	assert glue.contains('g_diag.server.serves_reset = true')
	hc, ho, hg := generate_host('default_table', same, '')
	assert hc == 0, ho
	assert !hg.contains('.services[') && !hg.contains('.nservices')
	for want in ['st.conn_diag.server.serves_reset = true', 'st.conn_diag.server.serves_comm_control = true',
		'st.conn_diag.server.faults = st.fmem.uds_ops()'] {
		assert hg.contains(want), 'missing: ${want}'
	}
}

// A table is generated into the server on BOTH owners through the one init (conn_init_lines), in
// SID order whatever the file's; a row's security level is a level the server serves, with no DID
// gate naming it.
fn test_a_service_table_is_generated_for_both_owners() {
	table := '
[uds.services]
"0x3E" = {}
"0x10" = {}
"0x2e" = { sessions = ["extended"], security = 1 }
"0x22" = {}
"0x11" = { sessions = ["extended"] }
"0x27" = {}
'
	code, out, glue := generate('table', diag_conn + table)
	assert code == 0, out
	steps := ['g_diag.server.services[0] = uds.Service{sid: 0x10}',
		'g_diag.server.services[1] = uds.Service{sid: 0x11, sessions: 0x04}',
		'g_diag.server.services[2] = uds.Service{sid: 0x22}',
		'g_diag.server.services[3] = uds.Service{sid: 0x27}',
		'g_diag.server.services[4] = uds.Service{sid: 0x2e, sessions: 0x04, security: 1}',
		'g_diag.server.services[5] = uds.Service{sid: 0x3e}',
		'g_diag.server.nservices = 6']
	mut at := -1
	for step in steps {
		i := glue[at + 1..].index(step) or {
			assert false, 'step "${step}" missing or out of order:\n${glue}'
			return
		}
		at = at + 1 + i
	}
	assert glue.contains('g_diag.server.security_levels = u8(0x01)'), 'the row\'s level is served'
	assert glue.contains('import comm.uds')
	// the host bridge: the same rows, and what only it performs (0x28, the fault memory's services)
	hc, ho, hg := generate_host('table', same, '
[uds.services]
"0x10" = {}
"0x28" = { sessions = ["extended"] }
"0x19" = {}
"0x27" = {}
"0x22" = {}
"0x2E" = {}
')
	assert hc == 0, ho
	for want in ['st.conn_diag.server.services[0] = uds.Service{sid: 0x10}',
		'st.conn_diag.server.services[1] = uds.Service{sid: 0x19}',
		'st.conn_diag.server.services[4] = uds.Service{sid: 0x28, sessions: 0x04}',
		'st.conn_diag.server.nservices = 6'] {
		assert hg.contains(want), 'missing: ${want}'
	}
}

// What a table may not say: a service this build does not perform, a session the service cannot
// run in, a level nothing can unlock — each refused, naming [uds]. `+` marks a case run beside a
// writable [[did]] gated on security level 1.
fn test_a_service_table_the_build_cannot_honour_is_refused() {
	gated := '\n[[did]]\nid = 0xF1AC\nbytes = "00"\nwrite = { session = ["extended"], security = 1 }\n'
	ok := '"0x10" = {}\n"0x22" = {}\n'
	sa := ok + '"0x27" = {}\n"0x2E" = {}\n'
	cases := {
		'comm_control':   [ok + '"0x28" = {}', 'nothing on the target gates its frames on CommunicationControl']
		'dtcs':           [ok + '"0x19" = {}', 'no fault memory']
		'clear':          [ok + '"0x14" = {}', 'no fault memory']
		'dtc_setting':    [ok + '"0x85" = {}', 'no fault memory']
		'no_seam':        [ok + '"0x27" = {}', 'nothing to unlock']
		'unknown':        [ok + '"0x31" = {}', 'comm/uds does not implement it']
		'programming':    [ok + '"0x11" = { sessions = ["programming"] }', 'programming session']
		'iso_session':    ['+"0x10" = {}\n"0x2E" = {}\n"0x27" = { sessions = ["default", "extended"] }', 'only in a non-default one']
		'stuck':          ['"0x10" = { sessions = ["extended"] }\n"0x22" = {}', 'no other session could ever be entered']
		'unreached':      ['"0x22" = {}\n"0x11" = { sessions = ["extended"] }', 'leaves out 0x10']
		'twice':          [ok + '"0x2e" = {}\n"0x2E" = {}', 'are one service, 0x2e']
		'tp_secured':     ['+' + sa + '"0x3E" = { security = 1 }', 'cannot need a security level']
		'sa_secured':     ['+"0x10" = {}\n"0x2E" = {}\n"0x27" = { security = 1 }', 'cannot need a security level']
		'locked_out':     ['+"0x10" = {}\n"0x27" = {}\n"0x2E" = { sessions = ["safety"], security = 1 }', 'the only one an application server unlocks in']
		'bad_level':      [ok + '"0x2E" = { security = 9 }', 'is not a 0x27 level']
		'bad_key':        [ok + '"0x2G" = {}', 'is not a service id']
		'bad_session':    [ok + '"0x2E" = { sessions = ["boot"] }', 'is not a session']
		'empty_session':  [ok + '"0x2E" = { sessions = [] }', 'sessions is empty']
		'unknown_field':  [ok + '"0x2E" = { transports = ["isotp"] }', 'a row takes `sessions` and `security`']
		'no_unlock':      ['+' + ok + '"0x2E" = {}', 'leaves out 0x27']
		'no_write':       ['+' + ok + '"0x27" = {}', 'nothing could write it']
	}
	for name, c in cases {
		rows := c[0].trim_left('+')
		did := if c[0].starts_with('+') { gated } else { '' }
		code, out, _ := generate('svc_${name}', diag_conn + did + '\n[uds.services]\n' + rows + '\n')
		assert code != 0, 'loom2v accepted service table case ${name}'
		assert out.contains(c[1]), '${name}: ${out}'
	}
	c2, o2, _ := generate('svc_empty', diag_conn + '\n[uds]\nservices = {}\n')
	assert c2 != 0 && o2.contains('services is empty'), o2
	// the server needs a transport
	c3, o3, _ := generate('uds_alone', '\n[uds]\ns3_ms = 1000\n')
	assert c3 != 0 && o3.contains('declare its [isotp] connection'), o3
	// the security settings need something to unlock
	c4, o4, _ := generate('uds_sa_idle', diag_conn + '\n[uds]\nsecurity_attempts = 2\n')
	assert c4 != 0 && o4.contains('there is nothing to unlock'), o4
}

// The pre-[uds] layout is refused with the move it needs — never translated.
fn test_the_old_isotp_layout_is_refused_with_its_migration() {
	old := '
[[isotp]]
name          = "diag"
bus           = "can0"
rx_id         = 0x7B0
tx_id         = 0x7B8
s3_ms         = 5000
security_key  = "reference"
'
	code, out, _ := generate('old_array', old)
	assert code != 0, 'loom2v accepted [[isotp]]'
	assert out.contains('[[isotp]] is now the [isotp] table'), out
	assert out.contains('move s3_ms / security_key to [uds]'), out
	c2, o2, _ := generate('old_keys', diag_conn.replace('functional_id = 0x7DF', 'functional_id = 0x7DF\ns3_ms = 5000'))
	assert c2 != 0, 'loom2v accepted a server key in [isotp]'
	assert o2.contains('[isotp] `s3_ms` is the ISO 14229 server\'s setting') && o2.contains('move it to [uds]'), o2
	c3, o3, _ := generate('old_name', diag_conn.replace('[isotp]', '[isotp]\nname = "diag"'))
	assert c3 != 0 && o3.contains('[isotp] `name` is gone'), o3
}
