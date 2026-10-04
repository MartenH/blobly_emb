module main

// @verifies REQ-COM-008 REQ-E2E-002 REQ-DIAG-011
import os
import time

// The ThreadX comm thread's receive path (docs/diagnostics.md R5): a frame with a deadline, E2E or a
// signal status is checked on the comm thread by the host bridge's own templates (gen_rx.v) and
// com.RxMonitor, its signals cross to the FBs whole through the byte IOC, a signal-status fault is
// debounced there, and 0x28 and NM's sleep gate it. Runs the real generator on
// testdata/threadx_node (Command arrives on CmdFrame from the Tester) with its FBs on one thread.
const rt_fixture = os.join_path(@DIR, 'testdata', 'threadx_node')

const rt_bin = os.join_path(os.temp_dir(), 'loom2v_rx_target_${os.getpid()}_${time.now().unix_nano()}')

const rt_conn = '
[isotp]
bus           = "can0"
rx_id         = 0x7B0
tx_id         = 0x7B8
functional_id = 0x7DF
'

const rt_status = 'fields = { code = "u32", status = "RxStatus" }'

// CmdFrame grown to 8 bytes with a CRC and a counter, and its E2E contract in the DBC (blobly_net's
// docs/dbc_attributes.md): Data ID 0x55, CRC byte 4, counter byte 5, a 300 ms sender-loss timeout
const rt_e2e_frame = 'BO_ 291 CmdFrame: 8 Tester
 SG_ Command : 0|32@1+ (1,0) [0|4294967295] "" SUT
 SG_ CmdCrc : 32|8@1+ (1,0) [0|255] "" SUT
 SG_ CmdCtr : 40|4@1+ (1,0) [0|15] "" SUT'

const rt_e2e_attrs = '
BA_DEF_ BO_ "E2ECounterSignal" STRING;
BA_DEF_ BO_ "E2ECrcSignal" STRING;
BA_DEF_ BO_ "E2EProfile" STRING;
BA_DEF_ BO_ "E2EDataId" INT 0 65535;
BA_DEF_ BO_ "E2ETimeout" INT 0 65535;
BA_ "E2ECounterSignal" BO_ 291 "CmdCtr";
BA_ "E2ECrcSignal" BO_ 291 "CmdCrc";
BA_ "E2EProfile" BO_ 291 "P01";
BA_ "E2EDataId" BO_ 291 85;
BA_ "E2ETimeout" BO_ 291 300;
'

const rt_faults = '
[[fault]]
name   = "CmdTimeout"
dtc    = 0xC16400
signal = "Command"
on     = "timeout"

[[fault]]
name   = "CmdIntegrity"
dtc    = 0xC46400
signal = "Command"
on     = "integrity"

[[fault]]
name   = "CmdLost"
dtc    = 0xC46401
signal = "Command"
on     = "lost"

[fault_memory]
cycle = "power"

[nvm]
min_write_ms = 1000
'

fn testsuite_begin() {
	r := os.execute('${@VEXE} -enable-globals -o ${rt_bin} ${os.join_path(@VMODROOT, 'tools', 'loom2v')}')
	assert r.exit_code == 0, r.output
}

fn testsuite_end() {
	os.rm(rt_bin) or {}
}

// rt_one_thread: the fixture's FBs on its first thread
fn rt_one_thread(src string) string {
	mut s := src
	for t in ['load_mid', 'ctrl_slow'] {
		at := s.index('  [[partition.thread]]\n  name     = "${t}"') or { panic('no thread ${t}') }
		end := s.index_after('\n\n', at) or { panic('no end of thread ${t}') }
		s = s[..at] + s[end + 2..]
		s = s.replace('thread    = "${t}"', 'thread    = "load_fast"')
	}
	return s
}

// rt_generate runs loom2v on the one-thread fixture with `edit` applied to its ecu.toml and `extra`
// appended, and `e2e` on CmdFrame in the DBC; returns the exit code, the output and the glue.
fn rt_generate(name string, edit fn(string) string, extra string, e2e bool) (int, string, string) {
	tmp := os.join_path(os.temp_dir(), 'rx_target_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	os.mkdir_all(tmp) or { panic(err) }
	src := os.read_file(os.join_path(rt_fixture, 'ecu.toml')) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	os.write_file(ecu, edit(rt_one_thread(src)) + extra) or { panic(err) }
	mut dbc := os.read_file(os.join_path(rt_fixture, 'bus.dbc')) or { panic(err) }
	if e2e {
		dbc = dbc.replace('BO_ 291 CmdFrame: 4 Tester\n SG_ Command : 0|32@1+ (1,0) [0|4294967295] "" SUT', rt_e2e_frame) + rt_e2e_attrs
	}
	dbcp := os.join_path(tmp, 'bus.dbc')
	os.write_file(dbcp, dbc) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${rt_bin} ${ecu} ${dbcp} ${os.join_path(tmp, 'sig.v')} ' + '${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }
}

fn with_status(src string) string {
	return src.replace('fields = { code = "u32" }', rt_status)
}

// in_order_rt asserts every step appears in `glue`, each after the one before it
fn in_order_rt(glue string, steps []string) {
	mut at := -1
	for step in steps {
		i := glue[at + 1..].index(step) or {
			assert false, 'step "${step}" missing or out of order (after offset ${at})'
			return
		}
		at = at + 1 + i
	}
}

// A COM deadline on the target: armed at the comm thread's start, the frame judged by the monitor,
// the signal published WHOLE (status and all) to the byte IOC, read there by its FB, and the
// deadline polled after the drain and NM's tick. The lean whole-frame copy is not used for it.
fn test_a_received_deadline_reaches_the_fb_with_its_status() {
	code, out, glue := rt_generate('deadline', with_status, '
[[frame]]
name = "CmdFrame"
bus  = "can0"
rx   = { timeout_ms = 200 }
', false)
	assert code == 0, out
	in_order_rt(glue, [
		'struct CommRx_state {',
		'rxm_cmd_frame com.RxMonitor',
		'rxg com.RxGate',
		'g_crx CommRx_state',
		'fn comm_thread_entry(',
		'mut st := &g_crx',
		'st.rxm_cmd_frame.com.timeout_us = 200000',
		'st.rxm_cmd_frame.start(C.board_now_us())',
		'for {',
		'now := C.board_now_us()',
		// NM's sleep is a silence too: the deadline must not fire while the network is asleep
		'st.rxg.sample(true, g_nm.awake())',
		'for ch.recv(mut rx) {',
		'if rx.id == cmd_frame_id && rx.len == cmd_frame_dlc && rx.ext == false {',
		'p_cmd_frame := st.rxm_cmd_frame.received(now, st.rxg.on)',
		'command.code = u32(cmd_frame_command_phys(rx.data))',
		'command.status = rx_status_of(p_cmd_frame)',
		'C.iocb_pub(0, &command)',
		'nm_up := g_nm.awake()', // after NM's tick ...
	])
	in_order_rt(glue, [
		'for ch.tx_ready() && g_nm.produce(t1, mut nm_txf) {',
		'if st.rxg.settle() {', // ... the silence's end and the deadline judged on this pass's NM state
		'st.rxm_cmd_frame.restart(now)',
		'if st.rxg.live() && st.rxm_cmd_frame.expire(now) {',
		'command.status = .timeout',
	])
	// the FB reads the whole struct where the comm thread published it, and boot sized its cell
	assert glue.contains('C.iocb_get(0, &inp.command)'), glue
	assert glue.contains('C.iocb_cfg(0, u16(sizeof(cfg_command))) // Command: received, checked'), glue
	assert !glue.contains('C.ioc_pub(${0}, g_rx_last'), 'the checked frame took the lean copy too'
	assert glue.contains('fn rx_status_of(p com.RxPublish) sig.RxStatus {')
}

// E2E from the DBC on the target: the frame checked by comm/e2e, judged by the monitor, its lost
// count published beside the status; a diagnostic server's 0x28 gates the publication.
fn test_an_e2e_frame_is_checked_on_the_comm_thread() {
	code, out, glue := rt_generate('e2e', fn (src string) string {
		return src.replace('fields = { code = "u32" }', 'fields = { code = "u32", status = "RxStatus", lost = "u16" }')
	}, rt_conn, true)
	assert code == 0, out
	in_order_rt(glue, [
		'st.rxm_cmd_frame.e2e.timeout_us = 300000',
		'if st.rxg.sample(g_diag.server.rx_enabled(), g_nm.awake()) {',
		'st.rxm_cmd_frame.silenced()',
		'chk_cmd_frame := st.rxm_cmd_frame.e2e.check(&rx.data[0], int(cmd_frame_dlc), u16(0x55), 4, 5)',
		'p_cmd_frame := st.rxm_cmd_frame.checked(now, chk_cmd_frame, st.rxg.on, st.rxg.suspended())',
		'command.lost = u16(st.rxm_cmd_frame.lost())',
		'C.iocb_pub(0, &command)',
		'match g_diag.on_frame(',
		'g_diag.serve()',
		'st.rxg.sample(g_diag.server.rx_enabled(), g_nm.awake())', // a 0x28 served now gates what follows
	])
}

// Signal-status faults on the target (REQ-DIAG-011): no FB code — the comm thread is the detector.
// Each publication steps the debouncers into the fault memory g_fmem right where it is published,
// the level is stepped at the pass top for a pass with none, before the FBs' reports are consumed.
fn test_a_signal_status_fault_is_debounced_on_the_comm_thread() {
	code, out, glue := rt_generate('faults', fn (src string) string {
		return src.replace('fields = { code = "u32" }', 'fields = { code = "u32", status = "RxStatus", lost = "u16" }')
	}, rt_conn + rt_faults, true)
	assert code == 0, out
	in_order_rt(glue, [
		'fsrc_command sig.RxStatus',
		'sdeb_0 fault.Debounce',
		'slost_2 u16',
		'g_fmem.slots[0].dtc = u32(0xc16400)',
		'st.sdeb_0 = fault.Debounce{',
		'for {',
		'st.fsrc_command = .never_received', // a status going stale when reception stops
		'if st.sev_0 && st.rxg.live() {',
		'st.sdeb_0.step(if st.fsrc_command == .timeout',
		'g_fmem.consume(0, st.sdeb_0.rep)',
		'C.iocb_pub(0, &command)',
		'st.fsrc_command = command.status',
		'st.sdeb_0.apply(g_fmem.control_gen(0), g_fmem.control_held(0))',
		'g_fmem.consume(2, st.sdeb_2.rep)',
		'st.slost_2 = command.lost',
	])
	// the receive status feeds no fault through the host's channels on a target
	assert !glue.contains('st.fmem'), "a target fault hook named the host bridge's memory"
}

// One implementation: the comm thread's branch for a frame is the host bridge's, but for where the
// signal goes (the publish seam) and which fault memory it reports into.
fn test_the_target_frame_arm_is_the_host_one() {
	mut m := Model{}
	m.frames.e2e_on['brake'] = true
	m.frames.frame_bus['brake'] = 'can0'
	m.frames.e2e_timeout_us['brake'] = 300_000
	m.frames.e2e_id['brake'] = 0x44
	m.frames.e2e_crc['brake'] = 4
	m.frames.e2e_ctr['brake'] = 5
	m.sig_of['Brake'] = SigInfo{
		name: 'Brake'
		bus: 'can0'
		val_field: 'kpa'
		val_type: 'u16'
		has_status: true
		lost_type: 'u16'
		dbc_msg: 'brake'
	}
	host := RxOwner{
		fmem: 'st.fmem'
		rx_on: 'st.conn_diag.server.rx_enabled()'
		publish: fn (si SigInfo, fld string) string {
			return 'PUBLISH(${fld})'
		}
	}
	target := RxOwner{
		fmem: 'g_fmem'
		rx_on: 'g_diag.server.rx_enabled()'
		publish: fn (si SigInfo, fld string) string {
			return 'PUBLISH(${fld})'
		}
	}
	h := rx_frame_arm(m, 'brake', ['Brake'], false, 'can0', host, '\t').join('\n')
	t := rx_frame_arm(m, 'brake', ['Brake'], false, 'can0', target, '\t').join('\n')
	assert h == t, 'host:\n${h}\ntarget:\n${t}'
	hs := rx_settle_lines(m, ['brake'], {
		'brake': ['Brake']
	}, 'can0', host, '\t').join('\n')
	ts := rx_settle_lines(m, ['brake'], {
		'brake': ['Brake']
	}, 'can0', target, '\t').join('\n')
	assert hs.replace('st.conn_diag.', 'g_diag.') == ts, 'host:\n${hs}\ntarget:\n${ts}'
}

// A byte-IOC cell has ONE reader slot: a checked signal read on two FB threads is refused.
fn test_a_checked_signal_read_on_two_threads_is_refused() {
	code, out, _ := rt_generate('two_threads', fn (src string) string {
		mut s := os.read_file(os.join_path(rt_fixture, 'ecu.toml')) or { panic(err) }
		s = with_status(s)
		// LoadFast (thread load_fast) reads Command too, beside Governor (ctrl_slow)
		return s.replace('  name      = "on_10ms"\n  period_ms = 10\n', '  name      = "on_10ms"\n  period_ms = 10\n  reads     = ["Command"]\n')
	}, '', false)
	assert code != 0
	assert out.contains('received signal "Command" is read on 2 threads'), out
}

// A frame with nothing to check keeps the lean copy — and 0x28 gates it once a server is there.
fn test_an_unchecked_frame_keeps_the_lean_copy() {
	code, out, glue := rt_generate('lean', fn (src string) string {
		return src
	}, rt_conn, false)
	assert code == 0, out
	assert !glue.contains('rxm_'), 'a plain frame grew a monitor'
	in_order_rt(glue, ['if rx.id == u32(0x123)', 'if st.rxg.on {', 'C.ioc_pub('])
}
