module main

import os
import comm.uds
import tools.candb
import tools.sysmodel

#flag -I @VMODROOT/boards/common
#include "diag_io_ok.h"

fn C.diag_io_ok(u16, u8) int

// @verifies REQ-DIAG-100 REQ-DIAG-103 REQ-DIAG-104 REQ-DIAG-106 REQ-DIAG-066
// 0x2F InputOutputControlByIdentifier as generated (docs/diagnostics.md §3.1 "Input/output
// control"): the server's control table on both owners (the gate within the 0x2F row, the range and
// default from the DBC), the tester's value substituted where the node ENCODES the signal — the
// target's local producer, a satellite's lanes on the comm thread, the host bridge — with the encode
// reading the substituted value, the live DID reading what is published, the target's conditions
// seam, and every refusal. Runs the real generator on scratch copies — a refusal is a panic, which
// cannot be caught in-process. Its own helpers: V compiles each _test.v as its own program.

const io_fixture = os.join_path(@DIR, 'testdata', 'threadx_node')

const io_params = 'control = { parameters = ["reset_to_default", "freeze_current_state", "short_term_adjustment"] }'

// the target fixture's diagnostic connection
const io_conn = '
[isotp]
bus           = "can0"
rx_id         = 0x7B0
tx_id         = 0x7B8
functional_id = 0x7DF

[[did]]
id    = 0xF190
ascii = "BLOBLY-TEST"
'

const io_nvm = '
[nvm]
min_write_ms   = 1000
sector_records = 4096
'

// a live DID on `sig` with `control` (a whole `control = ...` line)
fn io_did(id string, sig string, control string) string {
	return '\n[[did]]\nid     = ${id}\nsignal = "${sig}"\n${control}\n'
}

fn io_same(s string) string {
	return s
}

struct IoRun {
	code   int
	output string
	glue   string // the owner's gen/loom_gen.v
	sat    string // a generated satellite's, where there is one
}

// io_gen runs loom2v on a scratch copy of the config in directory `ex` — its ecu.toml edited and
// `extra` appended, its bus.dbc edited — laid out under a fresh directory, so a satellite's
// `image = "../<dir>"` lands inside it
fn io_gen(name string, ex string, edit fn (string) string, extra string, edit_dbc fn (string) string) IoRun {
	tmp := os.join_path(os.vtmp_dir(), 'io_control_${name}_${os.getpid()}')
	os.rmdir_all(tmp) or {}
	defer {
		os.rmdir_all(tmp) or {}
	}
	scratch := os.join_path(tmp, os.base(ex))
	os.mkdir_all(scratch) or { panic(err) }
	src := os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) }
	ecu := os.join_path(scratch, 'ecu.toml')
	os.write_file(ecu, edit(src) + extra) or { panic(err) }
	dbc_src := os.read_file(os.join_path(ex, 'bus.dbc')) or { panic(err) }
	dbc := os.join_path(scratch, 'bus.dbc')
	os.write_file(dbc, edit_dbc(dbc_src)) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	bin := sysmodel.tool_binary('loom2v') or { panic(err) }
	r := os.exec([bin, ecu, dbc, os.join_path(tmp, 'sig.v'), os.join_path(tmp, 'ports.v'), glue,
		os.join_path(tmp, 'manifest.csv')])
	mut sat := ''
	for f in os.ls(tmp) or { []string{} } {
		p := os.join_path(tmp, f, 'gen', 'loom_gen.v')
		if f != os.base(ex) && os.exists(p) {
			sat = os.read_file(p) or { '' }
		}
	}
	return IoRun{
		code:   r.exit_code
		output: r.output
		glue:   os.read_file(glue) or { '' }
		sat:    sat
	}
}

fn io_target(name string, extra string) IoRun {
	return io_gen(name, io_fixture, io_same, extra, io_same)
}

fn io_example(name string) string {
	return os.join_path(@VMODROOT, 'examples', name)
}

fn io_host(name string, edit fn (string) string, extra string, edit_dbc fn (string) string) IoRun {
	return io_gen(name, io_example('overspeed'), edit, extra, edit_dbc)
}

fn io_replace(s string, old string, new string) string {
	assert s.count(old) == 1, 'anchor not unique: ${old}'
	return s.replace(old, new)
}

// in_order: each step after the one before it
fn io_in_order(glue string, steps []string) {
	mut at := -1
	for step in steps {
		i := glue[at + 1..].index(step) or {
			assert false, 'step "${step}" missing or out of order (after offset ${at})'
			return
		}
		at = at + 1 + i
	}
}

// refused: loom2v exits non-zero, naming why
fn io_refused(r IoRun, why string) {
	assert r.code != 0, 'loom2v accepted it (want: ${why})'
	assert r.output.contains(why), r.output
}

// the target's local producer: the control table, the live DID reading what is published, and the
// encode of the frame reading the substituted value — never the FB's cell directly
fn test_the_target_substitutes_where_the_comm_thread_encodes() {
	r := io_target('local', io_conn + io_did('0xF1A0', 'Workload', io_params))
	assert r.code == 0, r.output
	g := r.glue
	for want in ['g_diag.server.ios[0] = uds.IoControl{', 'g_diag.server.nio = 1', 'did:      u16(0xf1a0)',
		'width:    4', 'lo:       i64(0)', 'hi:       i64(4294967295)', 'dflt:     i64(0)',
		'params:   u8(0x0f)', 'sessions: u8(0x04)',
		'v_1_ever := C.ioc_get_ever(0, &v_1, &v_1_b) != 0 // Workload',
		'srv.io_note(0, i64(v_1), v_1_ever)', 'v_1_pub := srv.io_published(0)',
		'srv.dids[1].data[3] = u8(v_1_pub)', 'fn C.diag_io_ok(u16, u8) int',
		'g_diag.server.io_ok = diag_io_ok_v'] {
		assert g.contains(want), 'missing: ${want}'
	}
	io_in_order(g, ['tv_io_on, tv_io_v := g_diag.server.io_held(0)',
		'if C.ioc_get_ever(0, &tv_a, &tv_b) != 0 || tv_io_on {',
		'tv_pub := if tv_io_on { u32(tv_io_v) } else { tv_a }', 'tf_raw0_x := (f64(tv_pub)', 'if ch.send(tf)'])
	start := g.index('tv_io_on, tv_io_v :=') or { -1 }
	end := g.index('if ch.send(tf)') or { -1 }
	assert start >= 0 && end > start
	assert !g[start..end].contains('f64(tv_a)'), 'the encode still reads the FB\'s cell'
	assert !g.contains('security: u8('), 'an ungated control got a level'
	// no control: the glue is what it was
	plain := io_target('plain', io_conn + io_did('0xF1A0', 'Workload', ''))
	assert plain.code == 0, plain.output
	for absent in ['io_held', 'io_note', 'diag_io_ok', '.ios[', '.nio', 'tv_pub'] {
		assert !plain.glue.contains(absent), 'an uncontrolled node got ${absent}'
	}
	assert plain.glue.contains('C.ioc_get(0, &v_1, &v_1_b) // Workload')
}

// the range and the default come from the DBC; the sessions are the control's within the 0x2F row
// (the default table's runs extended only); the row's level is the control's when it names none
fn test_the_table_carries_the_dbc_range_and_the_gate() {
	dbc := fn (d string) string {
		s := io_replace(d, 'SG_ Workload : 0|32@1+ (1,0) [0|4294967295] "" Tester',
			'SG_ Workload : 0|32@1+ (1,0) [10|300] "" Tester')
		return s + '\nBA_ "GenSigStartValue" SG_ 512 Workload 20;\n'
	}
	both := 'control = { parameters = ["short_term_adjustment"], session = ["extended", "safety"] }'
	r := io_gen('bounds', io_fixture, io_same, io_conn + io_did('0xF1A0', 'Workload', both), dbc)
	assert r.code == 0, r.output
	for want in ['lo:       i64(10)', 'hi:       i64(300)', 'dflt:     i64(20)', 'params:   u8(0x09)',
		'sessions: u8(0x04)'] {
		assert r.glue.contains(want), 'missing: ${want}'
	}
	table := '
[uds.services]
"0x10" = {}
"0x22" = {}
"0x27" = {}
"0x2F" = { security = 1 }
"0x3E" = {}
'
	t := io_target('row_level', io_nvm + '\n[uds]\n' + table + io_conn + io_did('0xF1A0', 'Workload', io_params))
	assert t.code == 0, t.output
	assert t.glue.contains('security: u8(1)')
	assert t.glue.contains('g_diag.server.security_levels = u8(0x01)')
}

// a satellite FB's value: substituted in the value lane the comm thread sends from — the latched
// lanes untouched — and the refresh latching whether a value ever came
fn test_a_satellite_signal_is_substituted_in_its_lane_on_the_comm_thread() {
	edit := fn (s string) string {
		mut t := io_replace(s, 'writes    = ["M4Count"]', 'writes    = ["M4Count", "M4Tick"]')
		t += '\n[[signal]]\nname   = "M4Tick"\nfields = { n = "u32" }\nfrom   = "m4"\nto     = "can0"\n'
		t += '\n[[frame]]\nname = "M4TickFrame"\nbus  = "can0"\ntx   = { mode = "cyclic", cycle_ms = 100 }\n'
		return t
	}
	dbc := fn (d string) string {
		return io_replace(d, 'BA_DEF_ BO_ "GenMsgCycleTime"', 'BO_ 514 M4TickFrame: 4 SUT\n SG_ M4Tick : 0|32@1+ (1,0) [0|1000] "" Tester\n\nBA_DEF_ BO_ "GenMsgCycleTime"')
	}
	r := io_gen('sat', io_example('h755_threadx'), edit, io_conn + io_did('0xF1A2', 'M4Tick', io_params),
		dbc)
	assert r.code == 0, r.output
	g := r.glue
	assert r.sat != '', 'the satellite image was not generated'
	assert !r.sat.contains('io_held') && !r.sat.contains('M4Tick_io'), 'the satellite saw the control'
	for want in ['g_didx_m4_tick_ever bool', 'g_didx_m4_tick_ever = true',
		'srv.io_note(0, i64(g_didx_m4_tick[1]), g_didx_m4_tick_ever)', 'hi:       i64(1000)'] {
		assert g.contains(want), 'missing: ${want}'
	}
	io_in_order(g, ['xcore_m4_tick_io_on, xcore_m4_tick_io_v := g_diag.server.io_held(0)',
		'xcore_m4_tick_pub := if xcore_m4_tick_io_on { u32(xcore_m4_tick_io_v) } else { xcore_m4_tick_lanes[0] }',
		'if xcore_m4_tick_have || xcore_m4_tick_io_on {', 'xcore_txf_raw0_x := (f64(xcore_m4_tick_pub)'])
	assert !g.contains('xcore_m4_tick_lanes[0] = '), 'the override was written into the latched lanes'
	// two fields: no controlEnableMask in v1
	m := io_gen('sat_two', io_example('h755_threadx'), io_same, io_conn + io_did('0xF1A2', 'M4Count',
		io_params), io_same)
	io_refused(m, 'has 2 fields')
}

// the host bridge: the field written over what was acquired, before the frame's encode reads it;
// the refresh noting the FB's bool through the one conversion; no conditions seam
fn test_the_host_bridge_substitutes_before_its_encode() {
	r := io_host('host', io_same, '', io_same)
	assert r.code == 0, r.output
	g := r.glue
	io_in_order(g, ['if osal.ioc_acquire2(warn_lamp_ch, &warn_lamp, u8(sizeof(warn_lamp))) || st.conn_diag.server.io_on(0) { // 0x2F',
		'if st.conn_diag.server.io_on(0) {', 'warn_lamp.on = st.conn_diag.server.io_published(0) != 0',
		'lamp_frame_warn_lamp_set(mut tx_lamp_frame.data, if warn_lamp.on {', 'tx_lamp_frame_any = true'])
	assert g.contains('srv.io_note(0, if v_6.on { i64(1) } else { i64(0) }, v_6_have)')
	assert g.contains('srv.dids[6].data[0] = if v_6_pub != 0 { u8(1) } else { u8(0) }')
	assert g.contains('st.conn_diag.server.ios[0] = uds.IoControl{')
	assert !g.contains('io_ok'), 'the host bridge has no conditions seam'
	// the committed glue is this one (CI's freshness gate holds it there)
	committed := os.read_file(os.join_path(io_example('overspeed'), 'gen', 'loom_gen.v')) or { '' }
	assert committed.contains('warn_lamp.on = st.conn_diag.server.io_published(0) != 0')
}

// a negative factor turns the range over: its bounds are ordered after the conversion
fn test_a_negative_factor_orders_the_bounds() {
	dbc := fn (d string) string {
		return io_replace(d, 'SG_ BrakeLost : 8|16@1+ (1,0) [0|65535] "" Tester', 'SG_ BrakeLost : 8|16@1- (-0.5,0) [0|10] "" Tester')
	}
	r := io_host('negative', io_same, io_did('0xF1B1', 'BrakeLost', io_params), dbc)
	assert r.code == 0, r.output
	i := r.glue.index('.ios[1] = uds.IoControl{') or { -1 }
	assert i >= 0, r.glue
	block := r.glue[i..].all_before('\t}\n')
	assert block.contains('lo:       i64(0)') && block.contains('hi:       i64(10)'), block
}

// REQ-DIAG-104: every control the server could not apply, refused at generation with its reason
fn test_a_control_the_server_cannot_apply_is_refused() {
	// no diagnostic connection: named, before anything indexes it
	io_refused(io_target('no_isotp', io_did('0xF1A0', 'Workload', io_params)), 'declare its [isotp] connection')
	// no live signal
	io_refused(io_target('bytes', io_conn + '\n[[did]]\nid    = 0x0300\nbytes = "00"\n${io_params}\n'),
		'has a `control` but no `signal`')
	// not a value the node sends on CAN from an FB
	io_refused(io_target('rx', io_conn + io_did('0xF1A0', 'Command', io_params)), 'is received by the node')
	io_refused(io_target('internal', io_conn + io_did('0xF1A0', 'LoadCmd', io_params)), 'stays inside the node')
	gw_isotp := '\n[isotp]\nbus   = "can0"\nrx_id = 0x7B0\ntx_id = 0x7B8\n'
	io_refused(io_gen('routed', io_example('gateway'), io_same, gw_isotp + io_did('0xF1A0', 'WheelFL',
		io_params), io_same), 'is no signal of this node')
	// on the host, another bus's bridge sends it
	io_refused(io_gen('other_bus', io_example('gateway'), io_same, gw_isotp + io_did('0xF1A0', 'WarnLamp',
		io_params), io_same), 'is sent on bus "can1", whose bridge is not the one serving')
	// an I/O output: a live DID of one is refused before the control is looked at (ecumodel: its
	// channel has one reader, the io thread) — the control's own rule is asked directly below
	beeper := fn (s string) string {
		return io_replace(s, '  writes    = ["WarnLamp", "SecureStatus"]', '  writes    = ["WarnLamp", "SecureStatus", "Beeper"]')
	}
	io_out := '\n[io]\ncore = 1\n\n[[io.gpio]]\nname      = "Beeper"\npin       = "PB0"\nperiod_ms = 10\ninit      = false\n\n[[signal]]\nname = "Beeper"\nfields = { on = "bool" }\nfrom = "ctrl"\nto   = "io"\n'
	io_refused(io_host('io_out', beeper, io_out + io_did('0xF1B1', 'Beeper', io_params), io_same),
		'diagnostic DID reads io signal Beeper')
	// wider than 32 bits
	u64f := fn (s string) string {
		return io_replace(s, 'name = "BrakeLost"\nfields = { count = "u16" }', 'name = "BrakeLost"\nfields = { count = "u64" }')
	}
	io_refused(io_host('u64', u64f, io_did('0xF1B1', 'BrakeLost', io_params), io_same), 'at most 32 bits')
	// one signal, one control; at most uds.max_ios
	io_refused(io_target('twice', io_conn + io_did('0xF1A0', 'Workload', io_params) + io_did('0xF1A1',
		'Workload', io_params)), 'already controls "Workload"')
	mut five := io_conn
	for i in 0 .. 5 {
		five += io_did('0xF1A${i}', 'Workload', io_params)
	}
	io_refused(io_target('five', five), '5 [[did]]s declare a `control`')
	// the parameters and the sessions
	io_refused(io_target('empty', io_conn + io_did('0xF1A0', 'Workload', 'control = { parameters = [] }')),
		'parameters is empty')
	for s in ['default', 'programming'] {
		io_refused(io_target('session_${s}', io_conn + io_did('0xF1A0', 'Workload', 'control = { parameters = ["short_term_adjustment"], session = ["${s}"] }')),
			'session names "${s}"')
	}
	io_refused(io_target('level_no_ext', io_nvm + io_conn + io_did('0xF1A0', 'Workload', 'control = { parameters = ["short_term_adjustment"], session = ["safety"], security = 1 }')),
		'not accepted in the extended session')
	// the 0x2F row: the default table's runs in extended only
	io_refused(io_target('default_safety', io_conn + io_did('0xF1A0', 'Workload', 'control = { parameters = ["short_term_adjustment"], session = ["safety"] }')),
		'control gate shares no session with [uds] services 0x2f')
	rows := fn (row string) string {
		return '\n[uds.services]\n"0x10" = {}\n"0x22" = {}\n"0x3E" = {}\n${row}\n'
	}
	io_refused(io_target('row_sessions', '\n[uds]\n' + rows('"0x2F" = { sessions = ["safety"] }') +
		io_conn + io_did('0xF1A0', 'Workload', io_params)), 'control gate shares no session')
	io_refused(io_target('row_level', io_nvm + '\n[uds]\n' + rows('"0x27" = {}\n"0x2F" = { security = 2 }') + io_conn +
		io_did('0xF1A0', 'Workload', 'control = { parameters = ["short_term_adjustment"], security = 1 }')),
		'control needs security 1, but [uds] services 0x2f needs 2')
	// judged on the gate the server enforces: the 0x2F row's level is the control's, and 0x27
	// unlocks only in extended, which the control's own session leaves out
	row_safety := '"0x27" = {}\n"0x2F" = { sessions = ["extended", "safety"], security = 1 }'
	io_refused(io_target('row_level_safety', io_nvm + '\n[uds]\n' + rows(row_safety) + io_conn +
		io_did('0xF1A0', 'Workload', 'control = { parameters = ["short_term_adjustment"], session = ["safety"] }')),
		'control needs security 1 but the sessions it is accepted in (its own and [uds] services 0x2f\'s) leave out the extended session')
	// the same rule for every DID access: a read the 0x22 row gates
	read_row := '\n[uds.services]\n"0x10" = {}\n"0x22" = { sessions = ["extended", "safety"], security = 1 }\n"0x27" = {}\n"0x3E" = {}\n'
	io_refused(io_target('read_row_level', io_nvm + '\n[uds]\n' + read_row + io_conn +
		'\n[[did]]\nid     = 0xF1A1\nsignal = "Workload"\nread   = { session = ["safety"] }\n'),
		'read needs security 1 but the sessions it is accepted in')
	io_refused(io_target('no_row', '\n[uds]\n' + rows('') + io_conn + io_did('0xF1A0', 'Workload',
		io_params)), 'leaves out 0x2f — nothing could control it')
	io_refused(io_target('row_no_control', '\n[uds]\n' + rows('"0x2F" = {}') + io_conn), 'no [[did]] declares a `control`')
	// weaker than the read gate: the 0x6F answer carries the value
	io_refused(io_target('read_level', io_nvm + io_conn +
		'\n[[did]]\nid     = 0xF1A0\nsignal = "Workload"\nread   = { session = ["extended"], security = 1 }\n${io_params}\n'),
		'needs no security level, but the DID\'s read needs 1')
	both := '"0x2F" = { sessions = ["extended", "safety"] }'
	io_refused(io_target('read_session', '\n[uds]\n' + rows(both) + io_conn +
		'\n[[did]]\nid     = 0xF1A0\nsignal = "Workload"\nread   = { session = ["extended"] }\ncontrol = { parameters = ["short_term_adjustment"], session = ["extended", "safety"] }\n'),
		'accepted in a session the DID\'s read refuses')
	// a value the DBC names outside the range is sent as itself, past what v1 holds a control to
	sna := fn (d string) string {
		s := io_replace(d, 'SG_ Workload : 0|32@1+ (1,0) [0|4294967295] "" Tester',
			'SG_ Workload : 0|32@1+ (1,0) [0|1000] "" Tester')
		return s + '\nVAL_ 512 Workload 4294967295 "SNA" ;\n'
	}
	io_refused(io_gen('sna', io_fixture, io_same, io_conn + io_did('0xF1A0', 'Workload', io_params),
		sna), 'names a value outside its range')
	// an initial value that is not a value of the field (1.5 of a u16)
	half := fn (d string) string {
		s := io_replace(d, 'SG_ BrakeLost : 8|16@1+ (1,0) [0|65535] "" Tester', 'SG_ BrakeLost : 8|16@1+ (0.5,0) [0|1000] "" Tester')
		return s + '\nBA_ "GenSigStartValue" SG_ 305 BrakeLost 3;\n'
	}
	io_refused(io_host('init_half', io_same, io_did('0xF1B1', 'BrakeLost', io_params), half), 'has the initial value 1.5')
}

// REQ-DIAG-104: a multiplexed signal, or a multiplexor, cannot carry a controlled value — the
// encoder writes the signal's bits and sets no multiplexor — so its control is refused, while the
// same frame without a control generates
fn test_a_control_of_a_multiplexed_signal_is_refused() {
	paged := fn (d string) string {
		return io_replace(d, ' SG_ WarnLamp : 0|1@1+ (1,0) [0|1] "" Tester', ' SG_ WarnLamp m0 : 0|1@1+ (1,0) [0|1] "" Tester\n SG_ LampPage M : 7|1@1+ (1,0) [0|1] "" Tester')
	}
	switch := fn (d string) string {
		return io_replace(d, ' SG_ WarnLamp : 0|1@1+ (1,0) [0|1] "" Tester', ' SG_ WarnLamp M : 0|1@1+ (1,0) [0|1] "" Tester\n SG_ LampExtra m1 : 3|1@1+ (1,0) [0|1] "" Tester')
	}
	// examples/overspeed controls WarnLamp; without that [[did]] the frames generate
	uncontrolled := fn (s string) string {
		return io_replace(s, '[[did]]\nid      = 0xF1B0\nsignal  = "WarnLamp"\ncontrol = { parameters = ["reset_to_default", "freeze_current_state", "short_term_adjustment"] }\n',
			'')
	}
	for name, dbc in {
		'mux_paged':  paged
		'mux_switch': switch
	} {
		plain := io_host('${name}_plain', uncontrolled, '', dbc)
		assert plain.code == 0, plain.output
	}
	io_refused(io_host('mux_paged', io_same, '', paged), '"WarnLamp" is multiplexed in the DBC (m0)')
	io_refused(io_host('mux_switch', io_same, '', switch), '"WarnLamp" is a multiplexor in the DBC (M)')
	assert io_mux_refusal(candb.Signal{ name: 'S', length: 8 }) == ''
}

// REQ-DIAG-066: a target whose only security level is a control's keeps its 0x27 state in the
// journal like any other, so it needs [nvm]
fn test_a_target_whose_only_level_is_a_controls_needs_storage() {
	gated := 'control = { parameters = ["short_term_adjustment"], security = 1 }'
	io_refused(io_target('level_no_nvm', io_conn + io_did('0xF1A0', 'Workload', gated)), 'needs [nvm]')
	r := io_target('level_nvm', io_nvm + io_conn + io_did('0xF1A0', 'Workload', gated))
	assert r.code == 0, r.output
	assert r.glue.contains('security: u8(1)')
	assert r.glue.contains('g_diag.server.security_levels = u8(0x01)')
}

// a signed field on the target: the table's sign and bounds, the refresh reading the cell back
// through its sign, the encode reading the substituted value as the field's cell reads — the local
// producer and a satellite's lanes (an i32 and an i16 field over the u32 layout both carry, whose
// unsigned DBC signal keeps a negative value off the wire — the host bridge's signed path is below)
fn test_a_signed_control_on_the_target() {
	edit := fn (s string) string {
		return io_replace(s, 'name = "Workload"\nfields = { v = "u32" }', 'name = "Workload"\nfields = { v = "i32" }')
	}
	dbc := fn (d string) string {
		return io_replace(d, 'SG_ Workload : 0|32@1+ (1,0) [0|4294967295] "" Tester', 'SG_ Workload : 0|32@1+ (1,0) [0|1000] "" Tester')
	}
	r := io_gen('signed', io_fixture, edit, io_conn + io_did('0xF1A0', 'Workload', io_params), dbc)
	assert r.code == 0, r.output
	g := r.glue
	for want in ['width:    4', 'signed:   true', 'lo:       i64(0)', 'hi:       i64(1000)',
		'srv.io_note(0, i64(i32(v_1)), v_1_ever)', 'v_1_pub := srv.io_published(0)'] {
		assert g.contains(want), 'missing: ${want}'
	}
	io_in_order(g, ['tv_io_on, tv_io_v := g_diag.server.io_held(0)',
		'tv_pub := if tv_io_on { u32(tv_io_v) } else { tv_a }', 'tf_raw0_x := (f64(i32(tv_pub))',
		'if ch.send(tf)'])
	sat_edit := fn (s string) string {
		mut t := io_replace(s, 'writes    = ["M4Count"]', 'writes    = ["M4Count", "M4Temp"]')
		t += '\n[[signal]]\nname   = "M4Temp"\nfields = { c = "i16" }\nfrom   = "m4"\nto     = "can0"\n'
		t += '\n[[frame]]\nname = "M4TempFrame"\nbus  = "can0"\ntx   = { mode = "cyclic", cycle_ms = 100 }\n'
		return t
	}
	sat_dbc := fn (d string) string {
		return io_replace(d, 'BA_DEF_ BO_ "GenMsgCycleTime"', 'BO_ 514 M4TempFrame: 4 SUT\n SG_ M4Temp : 0|32@1+ (1,0) [0|1000] "" Tester\n\nBA_DEF_ BO_ "GenMsgCycleTime"')
	}
	t := io_gen('sat_signed', io_example('h755_threadx'), sat_edit, io_conn + io_did('0xF1A2', 'M4Temp',
		io_params), sat_dbc)
	assert t.code == 0, t.output
	for want in ['width:    2', 'signed:   true', 'lo:       i64(0)', 'hi:       i64(1000)',
		'srv.io_note(0, i64(i32(g_didx_m4_temp[1])), g_didx_m4_temp_ever)'] {
		assert t.glue.contains(want), 'missing: ${want}'
	}
	io_in_order(t.glue, ['xcore_m4_temp_io_on, xcore_m4_temp_io_v := g_diag.server.io_held(0)',
		'xcore_m4_temp_pub := if xcore_m4_temp_io_on { u32(xcore_m4_temp_io_v) } else { xcore_m4_temp_lanes[0] }',
		'(f64(i32(xcore_m4_temp_pub))'])
}

// io_overspeed_build: examples/overspeed with its ecu.toml, bus.dbc and app sources edited (an app
// edit takes the file's name), generated and BUILT in a scratch directory — its glue
fn io_overspeed_build(name string, edit fn (string) string, edit_dbc fn (string) string, edit_app fn (string, string) string) string {
	repo := @VMODROOT
	ex := io_example('overspeed')
	tmp := os.join_path(os.vtmp_dir(), 'io_control_build_${name}_${os.getpid()}')
	os.rmdir_all(tmp) or {}
	defer {
		os.rmdir_all(tmp) or {}
	}
	for sub in ['gen', 'ports', 'sig', 'app'] {
		os.mkdir_all(os.join_path(tmp, sub)) or { panic(err) }
	}
	os.cp(os.join_path(ex, 'main.v'), os.join_path(tmp, 'main.v')) or { panic(err) }
	for f in os.ls(os.join_path(ex, 'app')) or { panic(err) } {
		src := os.read_file(os.join_path(ex, 'app', f)) or { panic(err) }
		os.write_file(os.join_path(tmp, 'app', f), edit_app(f, src)) or { panic(err) }
	}
	ecu := os.join_path(tmp, 'ecu.toml')
	os.write_file(ecu, edit(os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) })) or {
		panic(err)
	}
	dbc := os.join_path(tmp, 'bus.dbc')
	os.write_file(dbc, edit_dbc(os.read_file(os.join_path(ex, 'bus.dbc')) or { panic(err) })) or {
		panic(err)
	}
	glue := os.join_path(tmp, 'gen', 'loom_gen.v')
	tool := fn (name string) string {
		return sysmodel.tool_binary(name) or { panic(err) }
	}
	for cmd in [
		[tool('dbc2cfg'), dbc, os.join_path(tmp, 'gen', 'dbc_gen.v')],
		[tool('cfg2v'), ecu, os.join_path(tmp, 'gen', 'ecu_gen.v')],
		[tool('loom2v'), ecu, dbc, os.join_path(tmp, 'sig', 'signals_gen.v'),
			os.join_path(tmp, 'ports', 'ports_gen.v'), glue, os.join_path(tmp, 'gen', 'manifest.csv')],
	] {
		r := os.exec(cmd)
		assert r.exit_code == 0, '${cmd.join(' ')}\n${r.output}'
	}
	r := os.exec([@VEXE, '-cc', 'cc', '-gc', 'none', '-path', '@vlib|@vmodules|${repo}|${tmp}', '-o',
		os.join_path(tmp, 'app_bin'), tmp])
	assert r.exit_code == 0, r.output
	return os.read_file(glue) or { '' }
}

// io_overspeed_signed: BrakeLost made a signed i16 under a control, a second live DID on it and on
// VehicleSpeed, built (the host bridge's integer and signed paths, and a refresh reading one signal
// into two DIDs, compiled)
fn io_overspeed_signed() string {
	cfg := fn (s string) string {
		return io_replace(s, 'name = "BrakeLost"\nfields = { count = "u16" }', 'name = "BrakeLost"\nfields = { count = "i16" }') +
			io_did('0xF1B1', 'BrakeLost', io_params) + io_did('0xF1B2', 'BrakeLost', '') +
			io_did('0xF1A1', 'VehicleSpeed', '')
	}
	dbc := fn (d string) string {
		return io_replace(d, 'SG_ BrakeLost : 8|16@1+ (1,0) [0|65535] "" Tester', 'SG_ BrakeLost : 8|16@1- (1,0) [-100|100] "" Tester')
	}
	app := fn (f string, src string) string {
		if f == 'brake_monitor.v' {
			return io_replace(src, 'count: inp.brake_pressure.lost', 'count: i16(inp.brake_pressure.lost)')
		}
		return src
	}
	return io_overspeed_build('signed', cfg, dbc, app)
}

// a signed integer field on the host bridge: the table's sign, the refresh noting the typed field,
// the field written back as its own type before the encode — and the whole node compiles, with two
// live DIDs on the controlled signal, each reading the published value (REQ-DIAG-103), and two on
// an uncontrolled one
fn test_a_signed_control_on_the_host_bridge_builds() {
	g := io_overspeed_signed()
	for want in ['v_8_pub := srv.io_published(1)', 'srv.dids[8].data[0] = u8(v_8_pub >> 8)',
		'if osal.ioc_acquire2(vehicle_speed_ch, &v_9, u8(sizeof(v_9))) {'] {
		assert g.contains(want), 'missing: ${want}'
	}
	for want in ['st.conn_diag.server.ios[1] = uds.IoControl{', 'signed:   true', 'lo:       i64(-100)',
		'hi:       i64(100)', 'srv.io_note(1, i64(v_7.count), v_7_have)'] {
		assert g.contains(want), 'missing: ${want}'
	}
	io_in_order(g, ['|| st.conn_diag.server.io_on(1) { // 0x2F', 'if st.conn_diag.server.io_on(1) {',
		'brake_lost.count = i16(st.conn_diag.server.io_published(1))',
		'_brake_lost_set(mut tx_brake_report.data, f64(brake_lost.count))'])
}

// the host bridge declares no local of its own for a control: its locals there are the signals'
// snake names, and a DBC signal may be named like any identifier — a transmitted WarnLampIoOn
// beside the controlled WarnLamp builds (the control's temporaries were once warn_lamp_io_on)
fn test_a_signal_named_like_a_controls_temporary_builds() {
	cfg := fn (s string) string {
		t := io_replace(s, '  writes    = ["WarnLamp", "SecureStatus"]', '  writes    = ["WarnLamp", "SecureStatus", "WarnLampIoOn", "WarnLampIoV"]')
		return t +
			'\n[[signal]]\nname = "WarnLampIoOn"\nfields = { on = "bool" }\nfrom = "ctrl"\nto   = "can0"\ntransport = "double"\n' +
			'\n[[signal]]\nname = "WarnLampIoV"\nfields = { on = "bool" }\nfrom = "ctrl"\nto   = "can0"\ntransport = "double"\n'
	}
	dbc := fn (d string) string {
		return io_replace(d, ' SG_ WarnLamp : 0|1@1+ (1,0) [0|1] "" Tester', ' SG_ WarnLamp : 0|1@1+ (1,0) [0|1] "" Tester\n SG_ WarnLampIoOn : 1|1@1+ (1,0) [0|1] "" Tester\n SG_ WarnLampIoV : 2|1@1+ (1,0) [0|1] "" Tester')
	}
	app := fn (f string, src string) string {
		return src
	}
	g := io_overspeed_build('names', cfg, dbc, app)
	io_in_order(g, ['mut warn_lamp := sig.WarnLamp{}', '|| st.conn_diag.server.io_on(0) { // 0x2F',
		'mut warn_lamp_io_on := sig.WarnLampIoOn{}', 'mut warn_lamp_io_v := sig.WarnLampIoV{}'])
	assert !g.contains('io_held('), 'the host bridge declared the control\'s value as a local'
}

// io_sig: a single-field signal sent on can0 with DBC signal `sg`, its field of type `typ`
fn io_sig(typ string, sg candb.Signal) SigInfo {
	return SigInfo{
		name:      'S'
		external:  true
		bus:       'can0'
		val_type:  typ
		dbc_lanes: [sg]
	}
}

// the range and its tolerance: a bound is never moved past a whole value however large it is, a
// value between two raw steps is never offered, and a range end the field cannot state is refused —
// so what the server says is published is what the frame carries (comm/uds io_published)
fn test_the_bounds_are_exact_on_the_dbc_grid() {
	// a large range: the tolerance is the conversion's rounding, not a unit
	big := io_bounds(io_sig('u32', candb.Signal{ name: 'S', length: 32, maximum: 4000000000 })) or {
		panic(err)
	}
	assert big.lo == 0 && big.hi == 4000000000
	neg := io_bounds(io_sig('i32', candb.Signal{
		name:      'S'
		length:    32
		is_signed: true
		minimum:   -2000000000
		maximum:   2000000000
	})) or { panic(err) }
	assert neg.lo == -2000000000 && neg.hi == 2000000000
	// a scaled grid holding every whole value: factor 0.1, offset -40
	tenth := io_bounds(io_sig('i16', candb.Signal{
		name:    'S'
		length:  12
		factor:  0.1
		offset:  -40
		minimum: -40
		maximum: 200
	})) or { panic(err) }
	assert tenth.lo == -40 && tenth.hi == 200 && tenth.dflt == 0
	// a field cutting the DBC range: its own ends, no wholeness asked of the DBC's
	cut := io_bounds(io_sig('u8', candb.Signal{ name: 'S', length: 16, factor: 0.5, maximum: 300.5 })) or {
		panic(err)
	}
	assert cut.lo == 0 && cut.hi == 255
	// factor 2: 1 lies between two raw steps
	if _ := io_bounds(io_sig('u16', candb.Signal{ name: 'S', length: 8, factor: 2, maximum: 250 })) {
		assert false, 'a grid of step 2 was accepted'
	} else {
		assert err.msg().contains('1, a value of its field in its range, falls between two raw steps'), err.msg()
	}
	// offset 0.5 on factor 1, the field cutting both ends: no whole value is a step
	if _ := io_bounds(io_sig('u8', candb.Signal{
		name:      'S'
		length:    16
		is_signed: true
		offset:    0.5
		minimum:   -1000.5
		maximum:   1000.5
	}))
	{
		assert false, 'an offset grid was accepted'
	} else {
		assert err.msg().contains('0, a value of its field in its range, falls between two raw steps'), err.msg()
	}
	// a wide raw field with a large offset: 1 maps to raw 1000000000001.25 — a quarter of a step,
	// decided exactly on the DBC's decimals, never within a tolerance
	if _ := io_bounds(io_sig('u32', candb.Signal{ name: 'S', length: 48, factor: 0.8, offset: -800000000000 })) {
		assert false, 'a value a quarter step off the grid was accepted'
	} else {
		assert err.msg().contains('1, a value of its field in its range, falls between two raw steps'), err.msg()
	}
	// the same at 1e15 raw steps, where any error bound over the operands' magnitudes exceeds the
	// quarter step: 1 maps to raw 1000000000000001.25
	if _ := io_bounds(io_sig('u32', candb.Signal{ name: 'S', length: 50, factor: 0.8, offset: -800000000000000 })) {
		assert false, 'a value a quarter step off the grid at 1e15 raw steps was accepted'
	} else {
		assert err.msg().contains('1, a value of its field in its range, falls between two raw steps'), err.msg()
	}
	// 1 / factor a thousandth off whole: the fraction accumulates over the range (255 would go out
	// as 254.745), so it is refused however small it is per step
	f := 1.0 / 1.001
	if _ := io_bounds(io_sig('u8', candb.Signal{ name: 'S', length: 48, factor: f, offset: -1e12 * f })) {
		assert false, 'an off-integral 1 / factor was accepted'
	} else {
		assert err.msg().contains('falls between two raw steps'), err.msg()
	}
	// raw steps past what f64 converts exactly: 1e18 and 1e18 + 1 are one f64
	if _ := io_bounds(io_sig('bool', candb.Signal{
		name:    'S'
		length:  64
		offset:  -1e18
		maximum: 1
	}))
	{
		assert false, 'a mapping f64 cannot hold was accepted'
	} else {
		assert err.msg().contains('within 2^50'), err.msg()
	}
	// an exact grid whose field values sit at raw steps 2^51..2^51 + 255: in f64 the conversion
	// could round a value to a neighbour step
	if _ := io_bounds(io_sig('u8', candb.Signal{ name: 'S', length: 53, offset: -2251799813685248 })) {
		assert false, 'raw steps near 2^51 were accepted'
	} else {
		assert err.msg().contains('within 2^50'), err.msg()
	}
	// a narrow field on a wide signal whose width is its range: only the steps the field reaches are
	// judged, which f64 holds exactly — 53 and 64 bits are controlled as 52 are
	for n in [52, 53, 64] {
		narrow := io_bounds(io_sig('u32', candb.Signal{ name: 'S', length: n })) or {
			panic('${n} bits: ${err}')
		}
		assert narrow.lo == 0 && narrow.hi == 4294967295 && narrow.dflt == 0
	}
	// a wide raw field f64 holds exactly is still controlled: 40 bits, factor 1, offset -2^39
	wide := io_bounds(io_sig('i32', candb.Signal{ name: 'S', length: 40, offset: -549755813888 })) or {
		panic(err)
	}
	assert wide.lo == -2147483648 && wide.hi == 2147483647
	// an end inside the field's values that is not one: the encoder would saturate to it
	if _ := io_bounds(io_sig('u16', candb.Signal{ name: 'S', length: 16, factor: 0.5, maximum: 250.5 })) {
		assert false, 'a range ending at 250.5 was accepted'
	} else {
		assert err.msg().contains('ending at 250.5'), err.msg()
	}
}

// REQ-DIAG-104: the control's own refusal of an output another thread applies — asked directly,
// since a live DID of an I/O point's or an Ethernet signal is refused first by ecumodel's reader
// rule, which a whole run never gets past
fn test_an_output_of_another_thread_is_refused_by_the_control_itself() {
	m := Model{
		eth:         'eth0'
		isotp_conns: [IsotpConn{
			bus: 'can0'
		}]
	}
	assert io_signal_refusal(m, SigInfo{ name: 'S', io_out: true }).contains('written to an I/O point')
	assert io_signal_refusal(m, SigInfo{ name: 'S', io_in: true }).contains('comes in from an I/O point')
	assert io_signal_refusal(m, SigInfo{ name: 'S', external: true, bus: 'eth0' }).contains('sent on the Ethernet bus "eth0"')
	assert io_signal_refusal(m, SigInfo{ name: 'S', external: true, bus: 'can0' }) == ''
}

// the target's conditions seam as a node that states no conditions has it: the board's weak default
// (boards/common/diag_io_ok.h, which diag_board.c includes) run through the wrapper the glue
// generates — pinned as text below — accepts every control, so a server whose io_ok is that wrapper
// takes 01, 02 and 03 (REQ-DIAG-106)
fn diag_io_ok_v(did u16, parameter u8) bool {
	return C.diag_io_ok(did, parameter) != 0
}

fn test_the_board_default_seam_accepts_every_control() {
	r := io_target('seam', io_conn + io_did('0xF1A0', 'Workload', io_params))
	assert r.code == 0, r.output
	assert r.glue.contains('fn diag_io_ok_v(did u16, parameter u8) bool {\n\treturn C.diag_io_ok(did, parameter) != 0\n}'),
		'the generated wrapper is not the one run here'
	for p in [u8(1), 2, 3] {
		assert C.diag_io_ok(0xF1A0, p) == 1, 'the board default refuses parameter ${p}'
	}
	mut s := uds.Server{}
	s.init(64)
	s.ios[0] = uds.IoControl{
		did:      0xF1A0
		width:    1
		hi:       200
		params:   0x0E
		sessions: 0x04
	}
	s.nio = 1
	s.io_ok = diag_io_ok_v
	s.session = 0x03
	mut resp := []u8{len: 64}
	for req in [[u8(0x2F), 0xF1, 0xA0, 0x03, 0x07], [u8(0x2F), 0xF1, 0xA0, 0x02],
		[u8(0x2F), 0xF1, 0xA0, 0x01], [u8(0x2F), 0xF1, 0xA0, 0x00]] {
		n := s.handle(&req[0], req.len, unsafe { &resp[0] })
		assert n == 5 && resp[0] == 0x6F && resp[3] == req[3], 'refused ${req}: ${resp[..n]}'
	}
}
