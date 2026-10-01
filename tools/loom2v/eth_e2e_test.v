module main

import os
import time

// The SOME/IP receive path's E2E (REQ-E2E-002, #299): what loom2v refuses, by running the real
// generator on examples/host_someip with its config edited — a refusal is a panic, which cannot
// be caught in-process.

const eth_bin = os.join_path(os.temp_dir(), 'loom2v_eth_e2e_${os.getpid()}_${time.now().unix_nano()}')

fn testsuite_begin() {
	r := os.execute('${@VEXE} -enable-globals -o ${eth_bin} ${os.join_path(@VMODROOT, 'tools',
		'loom2v')}')
	assert r.exit_code == 0, r.output
}

fn testsuite_end() {
	os.rm(eth_bin) or {}
}

// host_someip_with generates examples/host_someip with its ecu.toml edited, in a scratch dir.
fn host_someip_with(name string, edit fn (string) string) (int, string, string) {
	ex := os.join_path(@VMODROOT, 'examples', 'host_someip')
	tmp := os.join_path(os.temp_dir(), 'eth_e2e_${name}_${os.getpid()}')
	os.mkdir_all(tmp) or { panic(err) }
	defer {
		os.rmdir_all(tmp) or {}
	}
	src := os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	os.write_file(ecu, edit(src)) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${eth_bin} ${ecu} ${os.join_path(tmp, 'bus.dbc')} ${os.join_path(tmp,
		'sig.v')} ${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }
}

const safe_e2e = 'e2e     = { data_id = 0x22, counter_pos = 1, crc_pos = 2, timeout_ms = 500 }'

fn test_the_example_generates_the_verdict_match() {
	code, out, glue := host_someip_with('ok', fn (s string) string {
		return s
	})
	assert code == 0, out
	assert glue.contains('match e2e_rx_bench_cmd_safe.receive(now, e2e_bench_cmd_safe) {')
	assert glue.contains('e2e_rx_bench_cmd_safe.arm(osal.now_us())'), 'not armed from start'
	assert glue.contains('if e2e_rx_bench_cmd_safe.expired(now) {')
}

fn test_a_received_eth_e2e_frame_without_a_timeout_is_refused() {
	code, out, _ := host_someip_with('notmo', fn (s string) string {
		return s.replace(safe_e2e, 'e2e     = { data_id = 0x22, counter_pos = 1, crc_pos = 2 }')
	})
	assert code != 0
	assert out.contains('"BenchCmdSafe" is E2E-protected and received, but its e2e has no timeout_ms'), out
}

fn test_a_signal_of_a_received_eth_e2e_frame_without_status_is_refused() {
	code, out, _ := host_someip_with('nostatus', fn (s string) string {
		return s.replace('fields = { level = "u8", status = "RxStatus" }', 'fields = { level = "u8" }')
	})
	assert code != 0
	assert out.contains('signal "LampCmdSafe" comes from the E2E-protected eth frame'), out
}

fn test_a_status_on_an_unprotected_eth_frame_is_refused() {
	// BenchCmd carries LampCmd with no E2E: nothing could ever report its timeout
	code, out, _ := host_someip_with('plainstatus', fn (s string) string {
		return s.replace('name = "LampCmd"\nfields = { level = "u8" }', 'name = "LampCmd"\nfields = { level = "u8", status = "RxStatus" }')
	})
	assert code != 0
	assert out.contains('is not E2E-protected'), out
}

fn test_a_timeout_on_a_sent_eth_frame_is_refused() {
	code, out, _ := host_someip_with('txtmo', fn (s string) string {
		i := s.index('name    = "BenchTelem"') or { panic('host_someip lost BenchTelem') }
		j := s.index_after('e2e', i) or { panic('BenchTelem lost its e2e') }
		k := s.index_after('}', j) or { panic('') }
		return s[..k] + ', timeout_ms = 500 ' + s[k..]
	})
	assert code != 0
	assert out.contains('"BenchTelem" sets e2e.timeout_ms, but it is SENT'), out
}

fn test_a_fractional_eth_timeout_is_refused_not_truncated() {
	code, out, _ := host_someip_with('fractmo', fn (s string) string {
		return s.replace(safe_e2e, 'e2e     = { data_id = 0x22, counter_pos = 1, crc_pos = 2, timeout_ms = 500.9 }')
	})
	assert code != 0
	assert out.contains('e2e.timeout_ms must be an integer number of ms'), out
}
