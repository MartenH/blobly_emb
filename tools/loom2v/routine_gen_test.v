module main

import os
import comm.uds
import toml
import tools.cfgschema
import tools.sysmodel

// [[routine]] generation (docs/diagnostics.md §3.1, gen_routine.v): every refusal REQ-DIAG-087
// names, and what is emitted on each owner — the ThreadX comm thread (testdata/threadx_node, its one
// partition cut to one thread, as a routine's FB needs) and the host bridge (examples/overspeed,
// which carries a routine). The real generator runs on a scratch copy: a refusal is a panic.

const rt_target_ex = os.join_path(@DIR, 'testdata', 'threadx_node')
const rt_host_ex = os.join_path(@VMODROOT, 'examples', 'overspeed')
const rt_sat_ex = os.join_path(@VMODROOT, 'examples', 'h755_threadx')

const rt_nvm = '
[nvm]
min_write_ms   = 1000
sector_records = 4096
'

const rt_conn = rt_nvm + '
[isotp]
bus           = "can0"
rx_id         = 0x7B0
tx_id         = 0x7B8
functional_id = 0x7DF

[[did]]
id    = 0xF190
ascii = "BLOBLYTESTNODE001"
'

// rt_one_thread: the fixture's partition with its first thread alone, every FB on it (a ThreadX
// image has one local partition; a routine's FB needs it single-threaded)
fn rt_one_thread(s string) string {
	mut out := s
	for t in ['load_mid', 'ctrl_slow'] {
		start := out.index('  [[partition.thread]]\n  name     = "${t}"') or { panic('fixture: no thread ${t}') }
		end := out[start + 1..].index('\n\n') or { panic('fixture: thread ${t} unterminated') }
		out = out[..start] + out[start + 1 + end + 2..]
		out = out.replace('thread    = "${t}"', 'thread    = "load_fast"')
	}
	return out
}

const rt_routine = '
[[routine]]
id        = 0x0201
name      = "Test"
start_in  = 1
start_out = 2
'

// the dev keys' public halves (examples/keys/README.md), for a [boot] node
const rt_boot = '
[boot]
image_key   = "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
session_key = "29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7"
'

// a [doip] node's service table: every state-changing row behind a level (REQ-NET-012)
const rt_doip = '
[uds.services]
"0x10" = {}
"0x22" = {}
"0x27" = {}
"0x31" = { sessions = ["extended"], security = 1 }

[doip]
address         = "192.168.0.50"
logical_address = 0x07B0
'

// rt_fb: an FB on thread `thr` whose one handler (of `period` ms) reads and writes the given names
fn rt_fb(name string, thr string, period int, reads string, writes string) string {
	return '
[[fb]]
name   = "${name}"
thread = "${thr}"

  [[fb.handler]]
  name      = "on_tick"
  period_ms = ${period}
  reads     = [${reads}]
  writes    = [${writes}] # trailing comment terminates the nested parse (vlang/v#27684)
'
}

fn rt_runner() string {
	return rt_fb('Runner', 'load_fast', 50, '"TestRequest"', '"TestResult"')
}

// the whole target config the refusals edit: a connection, the FB and the routine
fn rt_ok() string {
	return rt_conn + rt_runner() + rt_routine
}

struct RtGen {
	code  int
	out   string
	sig   string
	ports string
	glue  string
	mk    string
}

// rt_gen runs loom2v on a scratch copy of `ex`'s config, edited and with `extra` appended
fn rt_gen(name string, ex string, edit fn (string) string, extra string) RtGen {
	tmp := os.join_path(os.temp_dir(), 'routine_gen_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	scratch := os.join_path(tmp, os.base(ex))
	os.mkdir_all(scratch) or { panic(err) }
	src := os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) }
	ecu := os.join_path(scratch, 'ecu.toml')
	os.write_file(ecu, edit(src) + extra) or { panic(err) }
	dbc := os.join_path(scratch, 'bus.dbc')
	os.cp(os.join_path(ex, 'bus.dbc'), dbc) or { panic(err) }
	gen_dir := os.join_path(tmp, 'gen')
	os.mkdir_all(gen_dir) or { panic(err) }
	r := os.exec([sysmodel.tool_binary('loom2v') or { panic(err) }, ecu, dbc,
		os.join_path(tmp, 'sig.v'), os.join_path(tmp, 'ports.v'), os.join_path(gen_dir, 'loom_gen.v'),
		os.join_path(tmp, 'manifest.csv')])
	return RtGen{
		code:  r.exit_code
		out:   r.output
		sig:   os.read_file(os.join_path(tmp, 'sig.v')) or { '' }
		ports: os.read_file(os.join_path(tmp, 'ports.v')) or { '' }
		glue:  os.read_file(os.join_path(gen_dir, 'loom_gen.v')) or { '' }
		mk:    os.read_file(os.join_path(gen_dir, 'loom_build.mk')) or { '' }
	}
}

fn rt_same(s string) string {
	return s
}

fn rt_target(name string, extra string) RtGen {
	return rt_gen(name, rt_target_ex, rt_one_thread, extra)
}

fn rt_routine_with(key string) string {
	return rt_routine + key + '\n'
}

// in_order: each of `steps` found in `s`, each after the one before
fn in_order(s string, steps []string) bool {
	mut at := -1
	for step in steps {
		i := s[at + 1..].index(step) or { return false }
		at = at + 1 + i
	}
	return true
}

// @verifies REQ-DIAG-087
// Every refusal, each naming its reason.
fn test_a_routine_is_generated_only_where_it_can_run() {
	two := rt_fb('Second', 'load_fast', 50, '"TestRequest"', '')
	cases := {
		'no_isotp':          [rt_runner() + rt_routine, 'an [isotp] connection']
		'unknown_key':       [rt_conn + rt_runner() + rt_routine_with('later = 1'), 'a routine takes']
		'bad_mode':          [rt_conn + rt_runner() + rt_routine_with('mode = "later"'), 'is not "sync" or "async"']
		'programming':       [rt_conn + rt_runner() + rt_routine_with('sessions = ["programming"]'), "programming is the bootloader's"]
		'record_33':         [rt_conn + rt_runner() + rt_routine.replace('start_out = 2', 'start_out = 33'), 'start_out = 33 must be 0..32']
		'range_low':         [rt_ok().replace('id        = 0x0201', 'id        = 0x0100'), 'outside 0x0200..0xDFFF and 0xF000..0xFEFF']
		'range_e000':        [rt_ok().replace('id        = 0x0201', 'id        = 0xE000'), 'outside 0x0200..0xDFFF']
		'boot_id':           [rt_ok().replace('id        = 0x0201', 'id        = 0xFF00') + rt_boot, "the bootloader's own routine"]
		'duplicate_id':      [rt_ok() + rt_routine.replace('"Test"', '"Other"'), 'is already "Test"']
		'duplicate_name':    [rt_ok() + rt_routine.replace('0x0201', '0x0202'), 'duplicate [[routine]] "Test"']
		'stop_on_sync':      [rt_conn + rt_runner() + rt_routine_with('stop = true'), 'on a synchronous routine']
		'results_out':       [rt_conn + rt_runner() + rt_routine_with('results_out = 2'), '`results` is off']
		'default_no_level':  [rt_conn + rt_runner() + rt_routine_with('sessions = ["default", "extended"]'), 'from the default session with no 0x27 level']
		'level_no_extended': [rt_conn + rt_runner() + rt_routine_with('sessions = ["safety"]\nsecurity = 1'), 'leave out the extended session']
		'row_level_safety':  [rt_conn + rt_runner() + rt_routine_with('sessions = ["extended", "safety"]\nsecurity = 1') + '\n[uds.services]\n"0x10" = {}\n"0x22" = {}\n"0x27" = {}\n"0x31" = { sessions = ["safety"] }\n', 'leave out the extended session']
		'no_session_change': [rt_ok() + '\n[uds.services]\n"0x22" = {}\n"0x31" = {}\n', 'gives no way into the sessions']
		'row_missing':       [rt_ok() + '\n[uds.services]\n"0x10" = {}\n"0x22" = {}\n', 'leaves out 0x31']
		'row_disjoint':      [rt_ok() + '\n[uds.services]\n"0x10" = {}\n"0x22" = {}\n"0x31" = { sessions = ["safety"] }\n', 'share none with [uds] services 0x31']
		'row_level':         [rt_conn + rt_runner() + rt_routine_with('security = 1') + '\n[uds.services]\n"0x10" = {}\n"0x22" = {}\n"0x27" = {}\n"0x31" = { security = 2 }\n', 'one unlock cannot satisfy both']
		'timeout':           [rt_conn + rt_fb('Runner', 'load_fast', 100, '"TestRequest"', '"TestResult"') + rt_routine_with('timeout_ms = 110'), "not above Runner.on_tick's period (100 ms) plus 20 ms"]
		'no_reader':         [rt_conn + rt_fb('Runner', 'load_fast', 50, '', '"TestResult"') + rt_routine, 'must be read by exactly one FB handler']
		'two_readers':       [rt_ok() + two, 'must be read by exactly one FB handler']
		'request_written':   [rt_ok() + rt_fb('Second', 'load_fast', 50, '', '"TestRequest"'), 'the diagnostic server alone writes']
		'other_writer':      [rt_conn + rt_fb('Runner', 'load_fast', 50, '"TestRequest"', '') + rt_fb('Second', 'load_fast', 50, '', '"TestResult"') + rt_routine, 'must be written by the handler that reads']
		'result_read':       [rt_ok() + rt_fb('Second', 'load_fast', 50, '"TestResult"', ''), 'the diagnostic server alone reads']
		'collides_signal':   [rt_ok() + '\n[[signal]]\nname   = "TestResult"\nfields = { v = "u32" }\nfrom   = "app"\nto     = "app"\n', 'already a signal, a parameter or another routine']
		'collides_snake':    [rt_ok() + '\n[[signal]]\nname   = "TESTRequest"\nfields = { v = "u32" }\nfrom   = "app"\nto     = "app"\n', 'both are the port `test_request`']
		'collides_param':    [rt_ok() + '\n[[param]]\nname    = "TestRequest"\nfields  = { v = "u16" }\ndefault = { v = 1 }\n', 'already a signal, a parameter or another routine']
		'too_long':          [rt_conn.replace('functional_id = 0x7DF', 'functional_id = 0x7DF\nmax_message   = 8') + rt_runner() + rt_routine.replace('start_out = 2', 'start_out = 32'), 'longer than [isotp] max_message = 8 (REQ-DIAG-087)']
		'doip_start_out':    [rt_conn + rt_doip + rt_runner() + rt_routine.replace('start_out = 2', 'start_out = 20'), 'push_max']
	}
	for name, c in cases {
		g := rt_target('refuse_${name}', c[0])
		assert g.code != 0, 'loom2v accepted ${name}'
		assert g.out.contains(c[1]), '${name}: ${g.out}'
		if name == 'too_long' {
			assert !g.out.contains('REQ-CAN-TP-022'), 'the routine sizes are their own refusal'
		}
	}
	// the default session in a routine's own list, kept out by its 0x31 row: never started from
	// default, so it needs no level
	gd := rt_target('default_row', rt_conn + rt_runner() + rt_routine_with('sessions = ["default", "extended"]') +
		'\n[uds.services]\n"0x10" = {}\n"0x22" = {}\n"0x31" = { sessions = ["extended"] }\n')
	assert gd.code == 0, gd.out
	// the fixture as it is: its partition has three threads
	gm := rt_gen('refuse_multi_thread', rt_target_ex, rt_same, rt_ok())
	assert gm.code != 0 && gm.out.contains('multi-thread partition'), gm.out
	// five routines: more than the server holds
	mut five := rt_conn + rt_runner()
	for i in 0 .. 5 {
		five += rt_routine.replace('0x0201', '0x020${i + 1}').replace('"Test"', '"T${i}"')
	}
	g5 := rt_target('refuse_five', five)
	assert g5.code != 0 && g5.out.contains('at most ${uds.max_routines}'), g5.out
	// four routines and a fault-owning FB: more byte cells than the image's pool
	mut reads := []string{}
	mut writes := []string{}
	mut routines := ''
	for i in 0 .. 4 {
		reads << '"R${i}Request"'
		writes << '"R${i}Result"'
		routines += rt_routine.replace('0x0201', '0x020${i + 1}').replace('"Test"', '"R${i}"')
	}
	cells := rt_conn + rt_fb('Runner', 'load_fast', 50, reads.join(', '), writes.join(', ')) +
		routines + '\n[[fault]]\nname = "Stuck"\ndtc  = 0xD00100\nfrom = "Runner.on_tick"\n'
	gc := rt_target('refuse_cells', cells)
	assert gc.code != 0 && gc.out.contains('exceed the byte-IOC pool'), gc.out
	// a satellite core's FB, and a hand-written satellite's
	sat := fn (s string) string {
		return s.replace('name      = "on_10ms"\nperiod_ms = 10\nwrites    = ["M4Count"]',
			'name      = "on_10ms"\nperiod_ms = 10\nreads     = ["TestRequest"]\nwrites    = ["M4Count", "TestResult"]')
	}
	sat_extra := '\n[isotp]\nbus   = "can0"\nrx_id = 0x7B0\ntx_id = 0x7B8\n' + rt_routine
	gs := rt_gen('refuse_sat', rt_sat_ex, sat, sat_extra)
	assert gs.code != 0 && gs.out.contains('REQ-PLACE-013') && gs.out.contains('satellite core'), gs.out
	gx := rt_gen('refuse_ext', rt_sat_ex, fn [sat] (s string) string {
		return sat(s).replace('image = "../h755_m4_app"', 'external = true')
	}, sat_extra)
	assert gx.code != 0 && gx.out.contains('hand-written satellite'), gx.out
	// a host FB in a multi-thread partition too
	host_multi := fn (s string) string {
		return s.replace('[[fb]]\nname      = "SelfChecker"\nthread    = "ctrl_main"',
			'[[partition]]\nname = "twin"\ncore = 0\n  [[partition.thread]]\n  name = "twin_a"\n  [[partition.thread]]\n  name = "twin_b"\n\n[[fb]]\nname      = "SelfChecker"\nthread    = "twin_a"')
	}
	gh := rt_gen('refuse_host_multi', rt_host_ex, host_multi, '')
	assert gh.code != 0 && gh.out.contains('multi-thread partition'), gh.out
	// a bare-metal target: the routine refused by the generator, with no service table naming 0x31
	gb := rt_gen('refuse_bare', rt_target_ex, fn (s string) string {
		return rt_one_thread(s).replace('kind    = "threadx"', 'kind    = "baremetal"')
	}, rt_ok())
	assert gb.code != 0 && gb.out.contains('on a bare-metal [target]'), gb.out
	// and the service table's reason, for a row naming 0x31 there
	mut bare := Model{}
	bare.target.on = true
	bare.routines = [RoutineCfg{
		name: 'Test'
	}]
	assert diag_unbuilt(bare, 0x31).contains('bare-metal')
	bare.target.threadx = true
	assert diag_unbuilt(bare, 0x31) == ''
	bare.routines = []
	assert diag_unbuilt(bare, 0x31) == 'the node has no [[routine]]'
}

// @verifies REQ-DIAG-081 REQ-DIAG-082
// The ThreadX emission: the request and result types, the FB's ports, its glue (the op taken once
// per request; the record copied only inside a reported state, the result published every
// dispatch), the comm thread's share of `.housekeep` (the result read before the deadline is judged)
// and of `.reports`, the cells configured at boot after the fault
// cells, the server's table, and the byte IOC linked for a routines-only node.
fn test_the_target_emission() {
	g := rt_target('emit', rt_ok())
	assert g.code == 0, g.out
	for want in ['import comm.uds', 'pub struct TestRequest {', '\top uds.RoutineOp', '\toption [1]u8',
		'pub struct TestResult {', '\tstate uds.RoutineState', '\tnrc   u8', '\trecord [2]u8'] {
		assert g.sig.contains(want), 'sig: ${want}\n${g.sig}'
	}
	assert g.ports.contains('\ttest_request sig.TestRequest') && g.ports.contains('\ttest_result sig.TestResult')
	assert in_order(g.glue, ['\trtq_test uds.RoutineRequest', '\trtf_test uds.RoutineFb']), g.glue
	assert in_order(g.glue, ['fn handler_app_runner_on_tick(', '\tC.iocb_get(0, &st.rtq_test)',
		'\tinp.test_request.op = st.rtf_test.take(&st.rtq_test)', '\tif inp.test_request.op != .none {',
		'inp.test_request.option[k] = st.rtq_test.data[k]', 'st.runner.on_tick(inp, mut outp)',
		'\tif st.rtf_test.report(outp.test_result.state, outp.test_result.nrc) {',
		'\t\t\tst.rtf_test.res.data[k] = outp.test_result.record[k]', '\t\t}', '\t}',
		'\tC.iocb_pub(1, &st.rtf_test.res)']), g.glue
	// the result read before the housekeeping that judges a routine's deadline (comm/uds
	// pending.v: a result the FB published before it counts), the request published after it
	assert in_order(g.glue, ['// pass: housekeep', 'C.iocb_get(1, &g_diag.server.routines[0].res)',
		'g_diag.housekeep(', '// pass: reports', 'C.iocb_pub(0, &g_diag.server.routines[0].req)',
		'// pass: drain']), g.glue
	assert g.glue.count('&g_diag.server.routines[0].res)') == 1, g.glue
	assert in_order(g.glue, ['pub fn boot() {', 'C.iocb_cfg(0, u16(sizeof(uds.RoutineRequest)))',
		'C.iocb_cfg(1, u16(sizeof(uds.RoutineResult)))', 'C._tx_initialize_kernel_enter()']), g.glue
	assert in_order(g.glue, ['g_diag.server.routines[0] = uds.Routine{', 'id:          u16(0x0201)',
		'sessions:    u8(0x04)', 'start_in:    1', 'start_out:   2', 'timeout_us:  u64(10000) * 1000',
		'g_diag.server.nroutines = 1']), g.glue
	assert g.mk.contains('LOOM_FAULT_SRCS = $(REPO)/boards/common/iocb.c'), g.mk
	// no DoIP: nothing pushed
	assert !g.glue.contains('push_step') && !g.glue.contains('g_diag_push')
	// beside a fault-owning FB the routine's cells come after the fault's
	gf := rt_target('emit_fault', rt_ok() + '\n[[fault]]\nname = "Stuck"\ndtc  = 0xD00100\nfrom = "Runner.on_tick"\n')
	assert gf.code == 0, gf.out
	assert gf.glue.contains('C.iocb_get(2, &st.rtq_test)') && gf.glue.contains('C.iocb_pub(3, &st.rtf_test.res)'), gf.glue
}

// @verifies REQ-DIAG-081
// On a [doip] node a routine's later responses are pushed after the mailbox; a [doip] node with no
// routine emits none of it.
fn test_the_doip_push() {
	g := rt_target('doip', rt_conn + rt_doip + rt_runner() + rt_routine)
	assert g.code == 0, g.out
	assert g.glue.contains('\tg_diag_push [doipnet.push_max]u8')
	assert in_order(g.glue, ['doipnet.serve_mailbox(mut g_diag', 'if doipnet.take_push_sent() {',
		'g_diag.push_sent()', 'push_n := g_diag.push_step(&g_diag_push[0], doipnet.push_max)',
		'g_diag.pushed(doipnet.push_resp(&g_diag_push[0], push_n))']), g.glue
	// the routine's own gate names no level; its 0x31 row's (1) is its effective one, which the server
	// holds as the routine's, so a relock of level 1 asks it to stop (comm/uds stop_relocked_routines)
	assert in_order(g.glue, ['g_diag.server.routines[0] = uds.Routine{', 'sessions:    u8(0x04)',
		'security:    u8(1)', 'g_diag.server.nroutines = 1']), g.glue
	none_ := rt_target('doip_none', rt_conn + rt_doip.replace('"0x31" = { sessions = ["extended"], security = 1 }\n',
		'').replace('"0x27" = {}\n', ''))
	assert none_.code == 0, none_.out
	assert !none_.glue.contains('push_step') && !none_.glue.contains('g_diag_push')
}

// @verifies REQ-DIAG-081
// The host emission, in examples/overspeed's committed generated files (which CI's freshness gate
// keeps equal to what loom2v emits): the triple channels cfg2v allocates, the FB's glue, the
// bridge's share after the faults' and the server's table.
fn test_the_host_emission() {
	gen := os.join_path(rt_host_ex, 'gen')
	ecu := os.read_file(os.join_path(gen, 'ecu_gen.v')) or { panic(err) }
	assert ecu.contains('pub const routine_req_self_check_ch = ') && ecu.contains('pub const routine_res_self_check_ch = ')
	glue := os.read_file(os.join_path(gen, 'loom_gen.v')) or { panic(err) }
	assert in_order(glue, ['fn handler_ctrl_self_checker_on_50ms(',
		'osal.ioc_acquire(routine_req_self_check_ch, &st.rtq_self_check, u8(sizeof(st.rtq_self_check)))',
		'inp.self_check_request.op = st.rtf_self_check.take(&st.rtq_self_check)',
		'st.self_checker.on_50ms(inp, mut outp)',
		'if st.rtf_self_check.report(outp.self_check_result.state, outp.self_check_result.nrc) {',
		'st.rtf_self_check.res.data[k] = outp.self_check_result.record[k]',
		'osal.ioc_publish(routine_res_self_check_ch, &st.rtf_self_check.res, u8(sizeof(st.rtf_self_check.res)))']), glue
	assert in_order(glue, ['st.conn_diag.server.routines[0] = uds.Routine{', 'id:          u16(0x0201)',
		'results:     true', 'results_out: 2', 'st.conn_diag.server.nroutines = 1']), glue
	sig := os.read_file(os.join_path(rt_host_ex, 'sig', 'signals_gen.v')) or { panic(err) }
	assert sig.contains('import comm.uds') && sig.contains('pub struct SelfCheckRequest {')
}

// Every key cfgschema's routine table states is one a [[routine]] takes — loom2v reads the keys from
// that table, so a key added to the schema is never refused here as unknown.
fn test_every_schema_key_is_a_routine_key() {
	mut text := '[[routine]]\n'
	for k in cfgschema.ecu.table('routine').keys {
		val := match k.name {
			'id' { '0x0201' }
			'name' { '"Full"' }
			else { k.def }
		}
		assert val != '', 'schema row routine.${k.name} has no default: give it a value here'
		text += '${k.name} = ${val}\n'
	}
	doc := toml.parse_text(text) or { panic(err) }
	rs := parse_routines(doc)
	assert rs.len == 1 && rs[0].name == 'Full'
	src := os.read_file(os.join_path(@DIR, 'gen_routine.v')) or { panic(err) }
	assert src.contains("const routine_keys = cfgschema.ecu.table('routine').names()"), 'the keys a [[routine]] takes are the schema table\'s, not a second list'
}
