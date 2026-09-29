module main

import os

// The diagnostic server on a ThreadX comm thread (docs/diagnostics.md R2): what the generator
// wires, in what order, and what it refuses until the next R2 steps. Runs the real generator on
// examples/h735_threadx (ThreadX, NM, trace and shell on can0, no [nvm]) with a connection added —
// a refusal is a panic, which cannot be caught in-process.

const diag_conn = '
[[isotp]]
name          = "diag"
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
	root := @VMODROOT
	ex := os.join_path(root, 'examples', 'h735_threadx')
	tmp := os.join_path(os.temp_dir(), 'diag_target_${name}_${os.getpid()}')
	os.mkdir_all(tmp) or { panic(err) }
	defer {
		os.rmdir_all(tmp) or {}
	}
	src := os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) }
	ecu := os.join_path(ex, 'ecu_diag_${name}_${os.getpid()}.toml') // beside its imports
	os.write_file(ecu, src + extra) or { panic(err) }
	defer {
		os.rm(ecu) or {}
	}
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${loom2v_bin()} ${ecu} ${os.join_path(ex, 'bus.dbc')} ${os.join_path(tmp,
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
		'if g_diag.on_frame(',
		'g_diag.serve()',
		'nm_up := g_nm.awake()',
		'if !nm_up && !g_diag.link.idle() {',
		'g_diag.abandon()',
		'g_diag.produce(t1, mut diag_txf)',
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
	// nothing on the target performs a reset or gates its frames on 0x28 yet
	assert !glue.contains('g_diag.server.serves_reset = true')
	assert !glue.contains('g_diag.server.serves_comm_control = true')
}

fn test_a_live_did_is_refused_on_the_target() {
	code, out, _ := generate('live', diag_conn + '
[[did]]
id     = 0xF1A0
signal = "Workload"
')
	assert code != 0, 'loom2v accepted a live DID on ThreadX'
	assert out.contains('live DIDs on the target'), out
}

fn test_a_security_gate_is_refused_on_the_target() {
	code, out, _ := generate('sec', diag_conn + '
[[did]]
id    = 0xF1AC
bytes = "00"
write = { session = ["extended"], security = 1 }
')
	assert code != 0, 'loom2v accepted a security gate on ThreadX'
	assert out.contains('0x27 on the target'), out
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
