module main

// @verifies REQ-COM-008 REQ-E2E-002 REQ-DIAG-011
import os
import time
import tools.candb

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
[[did]]
id    = 0xF190
ascii = "RX"

[[fault]]
name   = "CmdTimeout"
dtc    = 0xC16400
signal = "Command"
on     = "timeout"
freeze = [0xF190]

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
		'if p_cmd_frame == .ok {', // the value only from a good frame
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
	assert !glue.contains('if rx.id == u32(0x123)'), 'the checked frame kept a lean arm too'
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
		'p_cmd_frame := st.rxm_cmd_frame.checked(now, chk_cmd_frame, st.rxg.on, st.rxg.receiving(), st.rxg.suspended())',
		'command.lost = u16(st.rxm_cmd_frame.lost())',
		'C.iocb_pub(0, &command)',
		'match g_diag.on_frame(',
		// a 0x28 served now gates what follows it in the drain
		'g_diag.serve()\n\t\t\t\t\t\tif st.rxg.sample(g_diag.server.rx_enabled(), g_nm.awake())',
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
		'now, st.rxg.live())', // the level is not judged while reception is paused
		'g_fmem.consume(0, st.sdeb_0.rep)',
		'C.iocb_pub(0, &command)',
		// a frame published while the network sleeps is no result and caches nothing: the
		// status, the steps, the event flags and the lost baseline all wait on receiving
		'if st.rxg.receiving() { // asleep: published, not judged',
		'st.fsrc_command = command.status',
		'st.sdeb_0.apply(g_fmem.control_gen(0), g_fmem.control_held(0))',
		'g_fmem.consume(2, st.sdeb_2.rep)',
		'st.slost_2 = command.lost',
	])
	// an occurrence the drain or a deadline consumed has its snapshot taken after the pass's last
	// consume and before the journal write
	in_order_rt(glue, ['C.iocb_pub(0, &command)', 't1 := C.board_now_us()', 'if st.rxg.settle()',
		'st.rxm_cmd_frame.expire(now)', 'if g_fmem.capture_due() {', 'g_fmem.persist('])
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

// A deadline is a check too: a frame with one takes the checked path even when its signal has no
// status — the FB then sees the zero value the deadline publishes, as on the host bridge.
fn test_a_deadline_without_a_status_is_still_checked() {
	code, out, glue := rt_generate('nostatus', fn (src string) string {
		return src
	}, '
[[frame]]
name = "CmdFrame"
bus  = "can0"
rx   = { timeout_ms = 200 }
', false)
	assert code == 0, out
	in_order_rt(glue, ['p_cmd_frame := st.rxm_cmd_frame.received(now, st.rxg.on)',
		'C.iocb_pub(0, &command)', 'if st.rxg.live() && st.rxm_cmd_frame.expire(now) {',
		'mut command := sig.Command{}', 'C.iocb_pub(0, &command)'])
}

// The byte-IOC numbering: the checked signals first, then each fault-owning FB's two cells — one
// numbering the FB glue, the comm thread and boot share.
fn test_fault_cells_follow_the_checked_signals() {
	code, out, glue := rt_generate('cells', fn (src string) string {
		return src.replace('fields = { code = "u32" }', rt_status)
	}, rt_conn + '
[[fault]]
name     = "LoadImplausible"
dtc      = 0xC40100
from     = "LoadSlow.on_100ms"
debounce = { kind = "counter", fail = 3, pass = 3 }

[fault_memory]
cycle = "power"

[nvm]
min_write_ms = 1000
', false)
	assert code == 0, out
	for want in ['C.iocb_pub(0, &command)', 'C.iocb_get(0, &inp.command)',
		'C.iocb_pub(1, &st.frep_load_slow)', 'C.iocb_get(1, &g_frep_load_slow)',
		'C.iocb_get(2, &st.fctl_load_slow)', 'C.iocb_pub(2, &g_fctl_load_slow)',
		'C.iocb_cfg(0, u16(sizeof(cfg_command)))', 'C.iocb_cfg(1, u16(sizeof(fcfg_rep)))'] {
		assert glue.contains(want), 'missing: ${want}'
	}
}

// 0x28's transmit gate covers a satellite's signals too: the comm thread sends them for it.
fn test_a_satellites_tx_waits_on_0x28() {
	mut m := Model{}
	m.target.threadx = true
	m.isotp_conns = [IsotpConn{
		name: 'diag'
		bus: 'can0'
	}]
	m.xcore_names = ['Pair', 'Wide']
	m.xcore_idx['Pair'] = 0
	m.xcore_xw_off['Wide'] = 0
	m.sig_of['Pair'] = SigInfo{
		name: 'Pair'
		external: true
		dbc_dlc: 4
		fields: [SigField{'a', 'u32'}]
		dbc_lanes: [candb.Signal{ name: 'PairA', length: 32 }]
	}
	m.sig_of['Wide'] = SigInfo{
		name: 'Wide'
		external: true
		wide: true
		dbc_dlc: 12
		fields: [SigField{'a', 'u32'}, SigField{'b', 'u32'}, SigField{'c', 'u32'}]
		dbc_lanes: [candb.Signal{ name: 'PairA', length: 32 }].repeat(3)
	}
	out := xcore_produce_drain(m).join('\n')
	assert out.count('if g_diag.server.tx_enabled() && C.xcore_layout_ok() != 0') == 2, out
}

// A frame checked only for its layout or its status keeps no deadline: no clock is read for it.
fn test_a_checked_frame_without_a_deadline_reads_no_clock() {
	code, out, glue := rt_generate('noclock', with_status, '', false)
	assert code == 0, out
	assert glue.contains('if rx.id == cmd_frame_id && rx.len == cmd_frame_dlc'), glue
	assert !glue.contains('now := C.board_now_us()'), 'an unused clock read'
}

// A byte-IOC cell carries at most IOC_MAX bytes (iocb.c parks the image at boot past it): a checked
// signal whose struct is larger is refused at generation, and the bound is ioc.h's.
fn test_a_checked_signal_too_big_for_a_cell_is_refused() {
	h := os.read_file(os.join_path(@VMODROOT, 'boards', 'common', 'ioc.h')) or { panic(err) }
	assert h.contains('#define IOC_MAX ${ioc_max}\n'), 'ioc_max is not ioc.h IOC_MAX'
	assert sig_struct_size(SigInfo{
		fields: [SigField{'level', 'u16'}, SigField{'status', 'RxStatus'}, SigField{'lost', 'u32'}]
	}) == 8
	wide := 'fields = { a = "f64", b = "f64", c = "f64", d = "f64", e = "f64", f = "f64", g = "f64", h = "f64", status = "RxStatus" }'
	code, out, _ := rt_generate('toobig', fn [wide] (src string) string {
		return src.replace('fields = { code = "u32" }', wide)
	}, '', false)
	assert code != 0
	assert out.contains('is 72 bytes as a struct, but a byte-IOC cell carries at most 64'), out
}

// The comm pass runs in ONE order (comm_pass_order), with the gate re-sampled wherever it can change
// and the snapshots after the last consume. Pinned on a node with everything that moves state
// mid-pass: a diagnostic connection (0x28 on CAN), NM (a wake inside the drain), an NM-driven
// operation cycle, signal-status faults with a snapshot.
fn test_the_comm_pass_runs_in_one_order() {
	faults := rt_faults.replace('[fault_memory]\ncycle = "power"\n', '')
	code, out, glue := rt_generate('order', fn (src string) string {
		return src.replace('fields = { code = "u32" }', 'fields = { code = "u32", status = "RxStatus", lost = "u16" }')
	}, rt_conn + faults, true)
	assert code == 0, out
	// the markers: a step with nothing on this node leaves none
	mut steps := []string{}
	for line in glue.split_into_lines() {
		t := line.trim_space()
		if t.starts_with('// pass: ') {
			steps << t.all_after('// pass: ')
		}
	}
	// every step but `remote` (no DoIP here; doip_target_test pins it), in the declared order
	assert steps == comm_pass_order.map(it.str()).filter(it != 'remote'), steps.str()
	in_order_rt(glue, [
		'// pass: open',
		'st.rxg.sample(g_diag.server.rx_enabled(), g_nm.awake())', // the first sampling
		'// pass: reports',
		'// pass: drain',
		'mut nm_seen := g_nm.awake()',
		'for ch.recv(mut rx) {',
		'p_cmd_frame := st.rxm_cmd_frame.checked(',
		'g_diag.serve()',
		'st.rxg.sample(g_diag.server.rx_enabled(), g_nm.awake())', // a 0x28 on CAN
		'g_nm.on_peers(',
		'if g_nm.awake() != nm_seen {', // an NM frame that woke the network ...
		'st.rxg.sample(g_diag.server.rx_enabled(), g_nm.awake())', // ... re-samples the gate
		'st.fsrc_command = .never_received', // ... clears what a level step could replay
		'g_fmem.cycle_start()', // ... and starts the cycle, before the next frame
		'// pass: tick',
		'g_nm.produce(t1, mut nm_txf)',
		'// pass: cycle',
		'g_fmem.end_cycle_after(t1',
		'// pass: settle',
		'if st.rxg.settle()',
		'st.rxm_cmd_frame.expire(now)', // a deadline occurrence, consumed ...
		'// pass: persist',
		'if g_fmem.capture_due() {', // ... captured before ...
		'g_fmem.persist(t1, false)', // ... the journal write
	])
}

// rt_generate_raw runs loom2v on an ecu.toml and DBC given whole
fn rt_generate_raw(name string, ecu string, dbc string) (int, string) {
	tmp := os.join_path(os.temp_dir(), 'rx_target_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	os.mkdir_all(tmp) or { panic(err) }
	os.write_file(os.join_path(tmp, 'ecu.toml'), ecu) or { panic(err) }
	os.write_file(os.join_path(tmp, 'bus.dbc'), dbc) or { panic(err) }
	r := os.execute('${rt_bin} ${os.join_path(tmp, 'ecu.toml')} ${os.join_path(tmp, 'bus.dbc')} ' + '${os.join_path(tmp, 'sig.v')} ${os.join_path(tmp, 'ports.v')} ${os.join_path(tmp, 'gen.v')}')
	return r.exit_code, r.output
}

// A frame fits its bus (frame_len_refusal) — asked for EVERY frame before any path splits: a
// received one the COM receive rule checks (which skips the lean copy's limits), a lean received
// one, a transmitted one, and the frame a raw route forwards. A 12-byte frame on a classic bus is
// never sent or never matched; a 9-byte one on an FD bus arrives as 12 and is never matched.
fn test_every_frame_fits_its_bus() {
	assert frame_len_refusal(8, false) == none
	assert frame_len_refusal(12, false) != none
	assert frame_len_refusal(12, true) == none
	assert frame_len_refusal(9, true) != none
	big := 'BO_ 291 CmdFrame: 12 Tester\n SG_ Command : 0|32@1+ (1,0) [0|4294967295] "" SUT\n SG_ CmdCrc : 32|8@1+ (1,0) [0|255] "" SUT\n SG_ CmdCtr : 40|4@1+ (1,0) [0|15] "" SUT'
	cases := {
		'checked': with_status
		'lean':    fn (src string) string {
			return src
		}
	}
	for name, edit in cases {
		code, out, _ := rt_generate('len_${name}', edit, '', false)
		assert code == 0, '${name}: ${out}'
		src := rt_one_thread(os.read_file(os.join_path(rt_fixture, 'ecu.toml')) or { panic(err) })
		dbc := (os.read_file(os.join_path(rt_fixture, 'bus.dbc')) or { panic(err) }).replace('BO_ 291 CmdFrame: 4 Tester\n SG_ Command : 0|32@1+ (1,0) [0|4294967295] "" SUT', big)
		c2, o2 := rt_generate_raw('len_${name}_big', edit(src), dbc)
		assert c2 != 0, '${name}: a 12-byte frame on a classic bus generated'
		assert o2.contains('frame "cmd_frame" on bus "can0" is 12 bytes on a classic bus'), o2
	}
	// a transmitted one
	src := rt_one_thread(os.read_file(os.join_path(rt_fixture, 'ecu.toml')) or { panic(err) })
	dbc := (os.read_file(os.join_path(rt_fixture, 'bus.dbc')) or { panic(err) }).replace('BO_ 512 WorkloadFrame: 4 SUT', 'BO_ 512 WorkloadFrame: 12 SUT')
	c3, o3 := rt_generate_raw('len_tx', src, dbc)
	assert c3 != 0 && o3.contains('frame "workload_frame" on bus "can0" is 12 bytes on a classic bus'), o3
	// the frame a raw route forwards, onto a classic destination
	route := '[import]\ndbc = "bus.dbc"\n\n[bus.can0]\ninterface = "vcan0"\nfd = true\n\n[bus.can1]\ninterface = "vcan1"\nfd = false\n\n[[route]]\nfrom = { bus = "can0", frame = "BigFrame" }\nto   = { bus = "can1" }\n'
	rdbc := 'VERSION ""\nBU_: A B\nBO_ 300 BigFrame: 12 A\n SG_ V : 0|32@1+ (1,0) [0|0] "" B\n'
	c4, o4 := rt_generate_raw('len_route', route, rdbc)
	assert c4 != 0 && o4.contains('forwarded onto bus "can1" is 12 bytes on a classic bus'), o4
}

// @verifies REQ-COM-010
// The ThreadX comm thread: its producer encodes the IOC cell through com.encode_raw with the bounds
// candb derives for dbc2cfg's `_set` too (a signed field read back through its sign), and serves the
// DID from the count it keeps.
fn test_the_target_comm_thread_counts_and_serves_it() {
	code, out, glue := rt_generate('tx_sat', fn (src string) string {
		return src
	}, rt_conn + '\n[[did]]\nid             = 0x0120\ntx_saturations = true\n', false)
	assert code == 0, out
	assert glue.contains('mut tx_sat := com.TxSaturations{}'), glue
	assert glue.contains('tf_raw0_x := (f64(tv_a) - 0.0) / 1.0'), glue
	assert glue.contains('tf_raw0, tf_raw0_sat := com.encode_raw(tf_raw0_x, 0.0, 4294967295.0, u64(0), u64(4294967295), u64(0), u64(0xffffffff))'), glue
	assert glue.contains('tf.data[3] = u8(tf_raw0 >> 24)')
	assert glue.contains('if ch.send(tf) {\n\t\t\t\ttx_sat.add(tf_sat)'), glue
	assert glue.contains('g_diag.server.dids[0].data[0] = u8(tx_sat.count >> 24)'), glue
	assert !glue.contains('u8(tv_a')
	assert cell_phys('i16', 'tv_a') == 'f64(i32(tv_a))'
	assert cell_phys('u32', 'tv_a') == 'f64(tv_a)'
	assert cell_phys('bool', 'tv_a') == 'f64(tv_a)'
}

// A comm-thread producer carries a field as `u32(field)`: a field it cannot carry whole (a float, a
// 64-bit integer) would reach the range check already truncated, so it is refused. And a value a
// node sends is held to its signal's range, so that range must be one a value can be sent in.
fn test_the_target_refuses_what_it_cannot_hold_to_a_range() {
	code, out, _ := rt_generate('tx_f32', fn (src string) string {
		return src.replace('fields = { v = "u32" }', 'fields = { v = "f32" }')
	}, '', false)
	assert code != 0
	assert out.contains('TX signal "Workload" field 0 is a f32, but a comm-thread producer carries a field as a u32'), out
	src := rt_one_thread(os.read_file(os.join_path(rt_fixture, 'ecu.toml')) or { panic(err) })
	dbc := (os.read_file(os.join_path(rt_fixture, 'bus.dbc')) or { panic(err) }).replace('SG_ Workload : 0|32@1+ (1,0) [0|4294967295]',
		'SG_ Workload : 0|32@1+ (1,0) [10|5]')
	c2, o2 := rt_generate_raw('tx_badrange', src, dbc)
	assert c2 != 0
	assert o2.contains('sent signal "Workload": range [10.0|5.0] has its minimum above its maximum'), o2
}
