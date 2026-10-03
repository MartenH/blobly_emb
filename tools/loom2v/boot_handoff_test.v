module main

import os

// [boot] (gen_diag.v): the programming handoff on a ThreadX comm thread (docs/bootloader.md P3) —
// what the generator wires and what it refuses. Runs the real generator on a copy of an example's
// config with a connection and [boot] appended (a refusal is a panic, which cannot be caught
// in-process).
// @verifies REQ-BOOT-003 (the build half: a [boot] node's 0x10 02 writes the request cell and resets
// once its answer has left — comm/uds and comm/diag's tests show the answer and the ordering)

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
'

fn boot_loom2v() string {
	bin := os.join_path(os.temp_dir(), 'loom2v_boot_handoff_${os.getpid()}')
	if !os.exists(bin) {
		r := os.execute('${@VEXE} -enable-globals -o ${bin} ${os.join_path(@VMODROOT, 'tools',
			'loom2v')}')
		assert r.exit_code == 0, r.output
	}
	return bin
}

// boot_gen runs loom2v on example `ex`'s config with `extra` appended: exit code, output, the glue
// and the gen/loom_build.mk it wrote
fn boot_gen(name string, ex string, extra string) (int, string, string, string) {
	tmp := os.join_path(os.temp_dir(), 'boot_handoff_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	dir := os.join_path(@VMODROOT, 'examples', ex)
	os.mkdir_all(tmp) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	src := os.read_file(os.join_path(dir, 'ecu.toml')) or { panic(err) }
	os.write_file(ecu, src + extra) or { panic(err) }
	dbc := os.join_path(tmp, 'bus.dbc')
	os.cp(os.join_path(dir, 'bus.dbc'), dbc) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${boot_loom2v()} ${ecu} ${dbc} ${os.join_path(tmp, 'sig.v')} ' +
		'${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }, os.read_file(os.join_path(tmp,
		'loom_build.mk')) or { '' }
}

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
	code, out, glue, mk := boot_gen('ok', 'h735_threadx', boot_conn)
	assert code == 0, out
	// the server: the handoff, behind its default row (the extended session, no level)
	assert glue.contains('g_diag.server.no_programming = true')
	assert glue.contains('g_diag.server.boot_handoff = true')
	assert glue.contains('g_diag.server.subs[0] = uds.SubService{sid: 0x10, sub: 0x02, sessions: 0x04}')
	assert glue.contains('g_diag.server.nsubs = 1')
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
		'for !ch.tx_idle() && C.board_now_us() - diag_t0 < 20000 {}',
		'if g_diag.reset_due() == uds.reset_into_boot {',
		'C.boot_handoff_request()',
		'C.diag_sys_reset()',
	])
	// the board side is linked because the code declares it
	assert mk.contains(r'$(REPO)/boards/common/boot_handoff.c'), mk
}

fn test_without_boot_the_programming_session_stays_refused() {
	code, out, glue, mk := boot_gen('none', 'h735_threadx', boot_conn.replace('[boot]', ''))
	assert code == 0, out
	assert glue.contains('g_diag.server.no_programming = true')
	assert !glue.contains('boot_handoff')
	assert !glue.contains('0xf195')
	assert !glue.contains('reset_into_boot')
	assert !mk.contains('boot_handoff.c'), mk
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
	code, out, glue, _ := boot_gen('row', 'h735_threadx', table + boot_conn)
	assert code == 0, out
	assert glue.contains('g_diag.server.subs[0] = uds.SubService{sid: 0x10, sub: 0x02, sessions: 0x04, security: 2}')
	assert glue.contains('g_diag.server.security_levels = u8(0x02)'), 'level 2 is served: the row names it'
	assert glue.contains('g_diag.server.nservices = 4'), 'the handoff row is not a service row'
}

fn test_a_handoff_that_cannot_be_performed_or_reached_is_refused() {
	for name, c in {
		'no_isotp':     ['[boot]\n', 'declare its [isotp] connection']
		'no_boot':      ['[uds.services]\n"0x10" = {}\n"0x10 02" = {}\n"0x22" = {}\n' +
			boot_conn.replace('[boot]', ''), 'the node has no [boot]']
		'programming':  ['[uds.services]\n"0x10" = {}\n"0x10 02" = { sessions = ["programming"] }\n"0x22" = {}\n' +
			boot_conn, 'names the programming session']
		'level_out':    ['[uds]\nsecurity_key = "reference"\n[uds.services]\n"0x10" = {}\n"0x10 02" = { sessions = ["default"], security = 1 }\n"0x22" = {}\n"0x27" = {}\n' +
			boot_conn, 'not accepted in the extended session']
		'other_sub':    ['[uds.services]\n"0x10" = {}\n"0x10 03" = {}\n"0x22" = {}\n' + boot_conn, 'the one sub-function row is the programming handoff']
		'no_0x10':      ['[uds.services]\n"0x10 02" = {}\n"0x22" = {}\n"0x3E" = {}\n' + boot_conn, 'leaves out 0x10']
		'no_shared':    ['[uds.services]\n"0x10" = { sessions = ["default"] }\n"0x10 02" = {}\n"0x22" = {}\n' +
			boot_conn, 'share no session']
		'did_clash':    [boot_conn + '\n[[did]]\nid    = 0xF195\nbytes = "00 00 00 01"\n', 'leave it to [boot]']
		'keys':         [boot_conn + 'enabled = true\n', '[boot] takes no keys yet']
	} {
		code, out, _, _ := boot_gen(name, 'h735_threadx', c[0])
		assert code != 0, '${name}: loom2v accepted it'
		assert out.contains(c[1]), '${name}: ${out}'
	}
	// a host build has no bootloader to reset into
	code, out, _, _ := boot_gen('host', 'overspeed', '\n[boot]\n')
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
	code, out, _, _ := boot_gen('doip_open', 'h735_threadx', doip)
	assert code != 0 && out.contains('the programming handoff (0x10 02)'), out
	gated := doip.replace('"0x22" = {}', '"0x10 02" = { security = 1 }\n"0x22" = {}')
	c2, o2, glue, _ := boot_gen('doip_gated', 'h735_threadx', gated)
	assert c2 == 0, o2
	// the answer leaves over TCP before the reset: the wait 0x11 already has, then the cell
	in_order(glue, [
		'for C.doip_tx_pending() != 0',
		'if g_diag.reset_due() == uds.reset_into_boot {',
		'C.diag_sys_reset()',
	])
}
