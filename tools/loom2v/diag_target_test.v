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
		'wait_ticks := if g_tm.is_dumping() || g_diag.link.busy() {',
		'g_diag.housekeep(',
		'for ch.recv(mut rx) {',
		'if g_nm.awake() && g_diag.on_frame(',
		'g_diag.serve()',
		'g_nm.hold(t1, g_diag.active())',
		'nm_up := g_nm.awake()',
		'g_diag.pump(t1, mut ch)',
		'if g_diag.reset_due() != 0 {',
		'diag.wire_drain(mut ch, diag_now_us)',
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
	steps := ['if g_diag.reset_due() != 0 {', 'diag.wire_drain(mut ch', 'nvm_flush_ok = g_nvm.mark_clean()',
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
		'no_read':        ['+"0x10" = {}\n"0x27" = {}\n"0x2E" = {}', 'nothing could read it']
		'sa_stranded':    ['+' + ok + '"0x2E" = {}\n"0x27" = { sessions = ["safety"] }', '0x27 leaves out the extended session']
		'gate_disjoint':  ['+' + ok + '"0x27" = {}\n"0x2E" = { sessions = ["safety"] }', 'shares no session with [uds] services 0x2e']
		'level_mismatch': ['+' + ok + '"0x27" = {}\n"0x2E" = { security = 2 }', 'one unlock cannot satisfy both']
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

// [boot] (docs/bootloader.md P3): the programming handoff on the comm thread — 0x10 02 answered, then
// the boot request cell and the reset by 0x11's path — and what the generator refuses.
// @verifies REQ-BOOT-003 (the build half: comm/uds and comm/diag's tests show the answer and its
// ordering, boot/prog_test.v the bootloader opening the promised session)

const boot_conn = '
[isotp]
bus           = "can0"
rx_id         = 0x7B0
tx_id         = 0x7B8
functional_id = 0x7DF

[[did]]
id    = 0xF190
ascii = "BLOBLY-TEST"

[boot]
image_key   = "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
session_key = "29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7"
'

fn in_order(glue string, steps []string) {
	mut at := -1
	for step in steps {
		i := glue[at + 1..].index(step) or {
			assert false, 'step "${step}" missing or out of order (after offset ${at})'
			return
		}
		at = at + 1 + i
	}
}

fn test_a_boot_node_hands_off_after_its_answer_has_left() {
	code, out, glue := generate('boot_ok', boot_conn)
	assert code == 0, out
	// the server: the handoff, with no row of its own — the server's default handoff sessions
	assert glue.contains('g_diag.server.no_programming = true')
	assert glue.contains('g_diag.server.boot_handoff = true')
	assert !glue.contains('g_diag.server.subs[0]') && !glue.contains('nsubs')
	// the conditions seam (REQ-BOOT-015) and the image-version DID after the configured ones
	assert glue.contains('fn boot_handoff_ok_v() bool {\n\treturn C.boot_handoff_ok() != 0\n}')
	assert glue.contains('g_diag.server.handoff_ok = boot_handoff_ok_v')
	assert glue.contains('id:  u16(0xf195)')
	assert glue.contains('g_diag.server.dids[1].data[0] = u8(boot_ver >> 24)')
	assert glue.contains('g_diag.server.ndid = 2')
	// performed as an answered reset: the controller drained, then the cell, then the reset
	in_order(glue, [
		'g_diag.server.ndid = 1',
		'g_diag.server.ndid = 2',
		'if g_diag.reset_due() != 0 {',
		'diag.wire_drain(mut ch, diag_now_us)',
		'if g_diag.reset_due() == uds.reset_into_boot {',
		'C.boot_handoff_request()',
		'C.diag_sys_reset()',
	])
	// the board side is linked because the code declares it (glue_build_lines, pinned in
	// threadx_makefiles_test.v)
	assert glue.contains('fn C.boot_handoff_request()')
}

// a [boot] node with no [[did]] and no service table still names comm.uds (the handoff's reset
// kind), and its generated glue type-checks
fn test_a_did_less_boot_node_imports_uds() {
	cfg := boot_conn.replace('[[did]]\nid    = 0xF190\nascii = "BLOBLY-TEST"\n', '')
	assert !cfg.contains('[[did]]')
	code, out, glue := generate('boot_nodid', cfg)
	assert code == 0, out
	assert glue.contains('import comm.uds'), 'a [boot] glue without comm.uds does not compile'
}

fn test_without_boot_the_programming_session_stays_refused() {
	code, out, glue := generate('boot_none', boot_conn.all_before('[boot]'))
	assert code == 0, out
	assert glue.contains('g_diag.server.no_programming = true')
	assert !glue.contains('boot_handoff')
	assert !glue.contains('0xf195')
	assert !glue.contains('reset_into_boot')
}

// the handoff's own row: its sessions and its level, the level served by 0x27 like any gate's
fn test_the_handoff_row_gates_it() {
	table := '
[uds]
security_key = "reference"

[uds.services]
"0x10" = {}
"0x10 02" = { sessions = ["extended"], security = 2 }
"0x22" = {}
"0x27" = {}
"0x3E" = {}
'
	code, out, glue := generate('boot_row', table + boot_conn)
	assert code == 0, out
	assert glue.contains('g_diag.server.subs[0] = uds.SubService{sid: 0x10, sub: 0x02, sessions: 0x04, security: 2}')
	assert glue.contains('g_diag.server.nsubs = 1')
	// a row naming no sessions takes the default ones, written out (a row's 0 is "every session")
	c2, o2, g2 := generate('boot_row_nosess', table.replace('sessions = ["extended"], ', '') + boot_conn)
	assert c2 == 0, o2
	assert g2.contains('uds.SubService{sid: 0x10, sub: 0x02, sessions: 0x04, security: 2}')
	assert glue.contains('g_diag.server.security_levels = u8(0x02)'), 'level 2 is served: the row names it'
	assert glue.contains('g_diag.server.nservices = 4'), 'the handoff row is not a service row'
}

fn test_a_handoff_that_cannot_be_performed_or_reached_is_refused() {
	for name, c in {
		'no_isotp':     ['[boot]' + boot_conn.all_after('[boot]'), 'declare its [isotp] connection']
		'no_boot':      ['[uds.services]\n"0x10" = {}\n"0x10 02" = {}\n"0x22" = {}\n' +
			boot_conn.all_before('[boot]'), 'the node has no [boot]']
		'programming':  ['[uds.services]\n"0x10" = {}\n"0x10 02" = { sessions = ["programming"] }\n"0x22" = {}\n' +
			boot_conn, 'names the programming session']
		'level_out':    ['[uds]\nsecurity_key = "reference"\n[uds.services]\n"0x10" = {}\n"0x10 02" = { sessions = ["default"], security = 1 }\n"0x22" = {}\n"0x27" = {}\n' +
			boot_conn, 'not accepted in the extended session']
		'other_sub':    ['[uds.services]\n"0x10" = {}\n"0x10 03" = {}\n"0x22" = {}\n' + boot_conn, 'the one sub-function row is the programming handoff']
		'no_0x10':      ['[uds.services]\n"0x10 02" = {}\n"0x22" = {}\n"0x3E" = {}\n' + boot_conn, 'leaves out 0x10']
		'no_shared':    ['[uds.services]\n"0x10" = { sessions = ["default"] }\n"0x10 02" = {}\n"0x22" = {}\n' +
			boot_conn, 'share no session']
		'did_clash':    [boot_conn + '\n[[did]]\nid    = 0xF195\nbytes = "00 00 00 01"\n', 'leave it to [boot]']
		'keys':         [boot_conn + 'enabled = true\n', '[boot] takes `image_key` and `session_key`']
		'no_key':       [boot_conn.all_before('session_key'), 'needs `session_key`']
		'bad_key':      [boot_conn.replace('"29acbae1', '"zz'), 'must be 64 hex characters']
		'same_keys':    [boot_conn.replace('29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7', '03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8'), 'are the same key']
		'zero_key':     [boot_conn.replace('29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7', '0'.repeat(64)), 'all zeros']
		'bus_index':    [boot_conn.replace('bus           = "can0"', 'bus           = "can10"'), 'names no single FDCAN index']
	} {
		code, out, _ := generate('boot_${name}', c[0])
		assert code != 0, '${name}: loom2v accepted it'
		assert out.contains(c[1]), '${name}: ${out}'
	}
	// `boot` is the table, nothing else (a top-level key, so written before the first table)
	cn, on, _ := generate_edited('boot_not_table', fn (src string) string {
		return 'boot = []\n' + src
	}, boot_conn.all_before('[boot]'))
	assert cn != 0 && on.contains('must be the [boot] table'), on
	// a host build has no bootloader to reset into
	tmp := os.join_path(os.temp_dir(), 'diag_target_boot_host_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	code, out, _ := run_in_scratch(tmp, 'overspeed', fn (src string) string {
		return src
	}, '\n[boot]' + boot_conn.all_after('[boot]'))
	assert code != 0 && out.contains('[boot] is a ThreadX target'), out
}

// over the network the handoff restarts the ECU for whoever connects: it needs its own level
// (REQ-NET-012, doipcfg.handoff_refusal — the rule syscheck applies too)
fn test_a_doip_nodes_handoff_needs_a_level() {
	doip := '
[uds]
security_key = "reference"

[uds.services]
"0x10" = {}
"0x11" = { sessions = ["extended"], security = 1 }
"0x22" = {}
"0x27" = {}
"0x3E" = {}
' + boot_conn.replace('ascii = "BLOBLY-TEST"', 'ascii = "BLOBLYH735THREADX"') + '
[doip]
address         = "192.168.0.50"
logical_address = 0x07B0
allow_bench_key = true
'
	code, out, _ := generate('boot_doip_open', doip)
	assert code != 0 && out.contains('the programming handoff (0x10 02)'), out
	gated := doip.replace('"0x22" = {}', '"0x10 02" = { security = 1 }\n"0x22" = {}')
	c2, o2, glue := generate('boot_doip_gated', gated)
	assert c2 == 0, o2
	// the answer leaves over TCP before the reset: the wait 0x11 already has, then the cell
	in_order(glue, [
		'for C.doip_tx_pending() != 0',
		'if g_diag.reset_due() == uds.reset_into_boot {',
		'C.diag_sys_reset()',
	])
}

// the node's bootloader is built from the same config: gen/boot_gen.h carries the [isotp] ids, its
// flow control, the FDCAN and frame format of its bus and the [boot] keys, and gen/loom_build.mk
// pulls in boot/boot.mk (the boot image, the app at the app slot, the image containers)
fn test_a_boot_node_gets_its_bootloader_config() {
	tmp := os.join_path(os.temp_dir(), 'diag_target_boot_gen_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	code, out, _ := run_in_scratch(tmp, 'h735_threadx', fn (src string) string {
		return src
	}, boot_conn.replace('functional_id = 0x7DF', 'functional_id = 0x7DF\nbs = 8\nstmin_ms = 2'))
	assert code == 0, out
	h := os.read_file(os.join_path(tmp, 'boot_gen.h')) or { panic(err) }
	for want in ['#define BOOT_CAN_IDX 0', '#define BOOT_CAN_FD 0', '#define BOOT_RX_ID 0x7b0u',
		'#define BOOT_TX_ID 0x7b8u', '#define BOOT_BS 8u', '#define BOOT_STMIN 2u',
		'#define BOOT_IMAGE_KEY {0x03, 0xa1, 0x07,', '#define BOOT_SESSION_KEY {0x29, 0xac, 0xba,'] {
		assert h.contains(want), '${want} missing:\n${h}'
	}
	// the generated endpoint IS the node's [isotp], whatever it is: the two cannot drift
	tmp3 := tmp + '_ids'
	defer {
		os.rmdir_all(tmp3) or {}
	}
	c3, o3, _ := run_in_scratch(tmp3, 'h735_threadx', fn (src string) string {
		return src
	}, boot_conn.replace('rx_id         = 0x7B0', 'rx_id         = 0x7C0').replace('tx_id         = 0x7B8',
		'tx_id         = 0x7C8'))
	assert c3 == 0, o3
	h3 := os.read_file(os.join_path(tmp3, 'boot_gen.h')) or { panic(err) }
	assert h3.contains('#define BOOT_RX_ID 0x7c0u') && h3.contains('#define BOOT_TX_ID 0x7c8u'), h3
	mk := os.read_file(os.join_path(tmp, 'loom_build.mk')) or { panic(err) }
	assert mk.contains('include ' + r'$(REPO)/boot/boot.mk'), mk
	// without [boot], neither
	tmp2 := tmp + '_none'
	defer {
		os.rmdir_all(tmp2) or {}
	}
	c2, o2, _ := run_in_scratch(tmp2, 'h735_threadx', fn (src string) string {
		return src
	}, boot_conn.all_before('[boot]'))
	assert c2 == 0, o2
	assert !os.exists(os.join_path(tmp2, 'boot_gen.h'))
	assert !(os.read_file(os.join_path(tmp2, 'loom_build.mk')) or { '' }).contains('boot.mk')
}

// an FD bus opens the bootloader in FD as it opens the application (zone_a: the edge bus is CAN-FD,
// its ISO-TP classic-sized) — the frame format a tester sees does not change across the handoff
fn test_a_boot_on_an_fd_bus_opens_it_in_fd() {
	mut m := Model{}
	m.isotp_conns = [IsotpConn{
		bus:   'can1'
		rx_id: 0x7C0
		tx_id: 0x7C8
	}]
	m.boot = BootCfg{
		on:          true
		image_key:   []u8{len: 32, init: 1}
		session_key: []u8{len: 32, init: 2}
	}
	h := boot_gen_h(m, fdcan_index('can1'), true)
	assert '#define BOOT_CAN_IDX 1 /* the [isotp] bus "can1": the comm thread\'s FDCAN */' in h
	assert '#define BOOT_CAN_FD 1 /* its frame format, as the application opens it */' in h
	assert fdcan_index('can10') == '' && fdcan_index('can3') == '' && fdcan_index('edge') == ''
}
