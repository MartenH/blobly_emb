module main

import os
import time

// E2E from the DBC (blobly_net#271): a frame the DBC protects needs no [[frame]].e2e, and on an
// ECU with one CAN bus no [[frame]] at all. Runs the real generator on examples/overspeed, whose
// BrakeStatus layout lives in its bus.dbc — a refusal is a panic, which cannot be caught in-process.

const e2e_bin = os.join_path(os.temp_dir(), 'loom2v_e2e_dbc_${os.getpid()}_${rand_suffix()}')

fn rand_suffix() string {
	return time.now().unix_nano().str()
}

// the generator is built once per run, from the source under test, and removed after it
fn testsuite_begin() {
	r := os.execute('${@VEXE} -enable-globals -o ${e2e_bin} ${os.join_path(@VMODROOT, 'tools',
		'loom2v')}')
	assert r.exit_code == 0, r.output
}

fn testsuite_end() {
	os.rm(e2e_bin) or {}
}

fn e2e_loom2v_bin() string {
	return e2e_bin
}

// overspeed_with generates examples/overspeed with its ecu.toml (and bus.dbc) edited, in a
// scratch directory.
fn overspeed_with(name string, edit fn (string) string) (int, string, string) {
	return overspeed_with_dbc(name, edit, fn (s string) string {
		return s
	})
}

fn overspeed_with_dbc(name string, edit fn (string) string, edit_dbc fn (string) string) (int, string, string) {
	ex := os.join_path(@VMODROOT, 'examples', 'overspeed')
	tmp := os.join_path(os.temp_dir(), 'e2e_dbc_${name}_${os.getpid()}')
	os.mkdir_all(tmp) or { panic(err) }
	defer {
		os.rmdir_all(tmp) or {}
	}
	src := os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	os.write_file(ecu, edit(src)) or { panic(err) }
	dbc := os.join_path(tmp, 'bus.dbc')
	os.write_file(dbc, edit_dbc(os.read_file(os.join_path(ex, 'bus.dbc')) or { panic(err) })) or {
		panic(err)
	}
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${e2e_loom2v_bin()} ${ecu} ${dbc} ${os.join_path(tmp,
		'sig.v')} ${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }
}

// cut removes the table starting at `head` up to the next `[[<kind>]]`.
fn cut(src string, head string, kind string) string {
	i := src.index(head) or { panic('overspeed lost `${head}` — update this test') }
	j := src.index_after('[[${kind}]]', i + 1) or { panic('`${head}` is not followed by a [[${kind}]]') }
	return src[..i] + src[j..]
}

// with_brake_frame gives BrakeStatus, which overspeed declares in its DBC alone, a [[frame]]
// carrying `e2e`.
fn with_brake_frame(e2e string) fn (string) string {
	return fn [e2e] (src string) string {
		return src + '\n[[frame]]\nname = "BrakeStatus"\nbus  = "can0"\ne2e  = ${e2e}\n'
	}
}

fn test_a_received_frame_the_dbc_protects_takes_its_deadline_from_the_dbc() {
	// overspeed itself: BrakeStatus has no [[frame]], its E2ETimeout is the 300 ms deadline
	code, out, glue := overspeed_with('rx', fn (src string) string {
		return src
	})
	assert code == 0, out
	assert glue.contains('check(&rx.data[0], int(brake_status_dlc), u16(0x44), 4, 5)')
	// the decision is RxState.receive_ex, suspended by the 0x28 latch (overspeed has a diag link)
	assert glue.contains('v_brake_status := st.e2e_rx_brake_status.receive_ex(now, e2e_brake_status, st.diag_rx_was_off)'), glue
	assert glue.contains('} else if v_brake_status == .integrity {'), glue
	// and without an E2ETimeout, a received protected frame is refused for having no deadline
	code2, out2, _ := overspeed_with_dbc('rxnotmo', fn (src string) string {
		return src
	}, fn (dbc string) string {
		return dbc.replace('BA_ "E2ETimeout" BO_ 769 300;', '')
	})
	assert code2 != 0
	assert out2.contains('"brake_status" has no deadline (rx.timeout_ms, e2e.timeout_ms, or E2ETimeout in the DBC)'), out2
	// with that fault gone, it is E2E's own rule that refuses (REQ-E2E-002)
	code3, out3, _ := overspeed_with_dbc('rxnotmo2', fn (src string) string {
		return cut(src, '[[fault]]\nname   = "BrakeMsgTimeout"', 'fault')
	}, fn (dbc string) string {
		return dbc.replace('BA_ "E2ETimeout" BO_ 769 300;', '')
	})
	assert code3 != 0
	assert out3.contains('"brake_status" is E2E-protected and received, but has no E2E timeout'), out3
	// a malformed E2ETimeout is said by name where a receiver needs it
	code4, out4, _ := overspeed_with_dbc('rxbadtmo', fn (src string) string {
		return src
	}, fn (dbc string) string {
		return dbc.replace('BA_ "E2ETimeout" BO_ 769 300;', 'BA_ "E2ETimeout" BO_ 769 soon;')
	})
	assert code4 != 0
	assert out4.contains('E2ETimeout "soon" in the DBC is not a number of ms'), out4 // via the fault that needs it
}

// lamp_dbc gives LampFrame CRC and counter signals and declares its E2E in the DBC.
fn lamp_dbc(dbc string) string {
	return dbc.replace(' SG_ WarnLamp : 0|1@1+ (1,0) [0|1] "" Tester',
		' SG_ WarnLamp : 0|1@1+ (1,0) [0|1] "" Tester\n SG_ LampCrc : 8|8@1+ (1,0) [0|255] "" Tester\n SG_ LampCounter : 16|4@1+ (1,0) [0|15] "" Tester') +
		'\nBA_ "E2ECounterSignal" BO_ 272 "LampCounter";\nBA_ "E2ECrcSignal" BO_ 272 "LampCrc";\nBA_ "E2EProfile" BO_ 272 "P01";\nBA_ "E2EDataId" BO_ 272 16;\nBA_ "E2ETimeout" BO_ 272 250;\n'
}

const lamp_stamp = 'protect(&tx_lamp_frame.data[0], int(lamp_frame_dlc), u16(0x10), 1, 2)'

fn test_a_sent_frame_whose_layout_only_the_dbc_declares_is_stamped() {
	code, out, glue := overspeed_with_dbc('tx', fn (src string) string {
		return src.replace('e2e  = { data_id = 0x10, crc_pos = 1, counter_pos = 2 }', '')
	}, lamp_dbc)
	assert code == 0, out
	assert glue.contains(lamp_stamp)
}

fn test_a_sent_frame_with_no_frame_table_is_stamped_on_the_one_can_bus() {
	code, out, glue := overspeed_with_dbc('notbl', fn (src string) string {
		return cut(src, '[[frame]]\nname = "LampFrame"', 'frame')
	}, lamp_dbc)
	assert code == 0, out
	assert glue.contains(lamp_stamp)
}

fn test_a_frame_override_contradicting_the_dbc_is_refused() {
	for e2e in ['{ crc_pos = 3 }', '{ timeout_ms = 200 }'] {
		code, out, _ := overspeed_with('contra', with_brake_frame(e2e))
		assert code != 0, e2e
		assert out.contains('contradicts the DBC'), out
	}
	// unless the difference is deliberate
	code, out, glue := overspeed_with('dev', with_brake_frame('{ timeout_ms = 200, deviates_from_dbc = true }'))
	assert code == 0, out
	assert glue.contains('check(&rx.data[0], int(brake_status_dlc), u16(0x44), 4, 5)')
}

fn test_a_declaration_on_another_nodes_frame_is_not_this_ecus() {
	// a shared DBC declares frames this ECU never carries, in profiles it does not implement
	code, out, _ := overspeed_with_dbc('foreign', fn (src string) string {
		return src
	}, fn (dbc string) string {
		return dbc + '\nBO_ 1500 Elsewhere: 8 Other\n SG_ C : 0|8@1+ (1,0) [0|255] "" Tester\n' +
			'BA_ "E2EProfile" BO_ 1500 "crc8_j1850";\nBA_ "E2ECrcSignal" BO_ 1500 "C";\n'
	})
	assert code == 0, out
}
