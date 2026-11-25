module main

import os
import tools.sysmodel

// E2E from the DBC (blobly_net#271): a frame the DBC protects needs no [[frame]].e2e, and on an
// ECU with one CAN bus no [[frame]] at all. Runs the real generator on examples/overspeed, whose
// BrakeStatus layout lives in its bus.dbc — a refusal is a panic, which cannot be caught in-process.

const e2e_bin = sysmodel.tool_binary('loom2v') or { panic(err) }

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
	r := os.exec([e2e_loom2v_bin(), ecu, dbc, os.join_path(tmp, 'sig.v'), os.join_path(tmp,
		'ports.v'), glue, os.join_path(tmp, 'manifest.csv')])
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
	// the decision is com.RxMonitor's, suspended by the 0x28 latch (overspeed has a diag link)
	assert glue.contains('p_brake_status := st.rxm_brake_status.checked(now, chk_brake_status, st.rxg.on, st.rxg.receiving(), st.rxg.suspended())'), glue
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

// p05_dbc puts BrakeStatus (received) and LampFrame (sent) on AUTOSAR E2E Profile 5: a 16-bit
// little-endian CRC and the counter's whole byte after it.
fn p05_dbc(dbc string) string {
	return lamp_dbc(dbc).replace('BO_ 272 LampFrame: 3 SUT', 'BO_ 272 LampFrame: 4 SUT').replace(' SG_ LampCrc : 8|8@1+ (1,0) [0|255] "" Tester\n SG_ LampCounter : 16|4@1+ (1,0) [0|15] "" Tester',
		' SG_ LampCrc : 8|16@1+ (1,0) [0|65535] "" Tester\n SG_ LampCounter : 24|8@1+ (1,0) [0|255] "" Tester').replace('BA_ "E2EProfile" BO_ 272 "P01";',
		'BA_ "E2EProfile" BO_ 272 "P05";').replace(' SG_ BrakeCrc : 32|8@1+ (1,0) [0|255] "" Tester\n SG_ BrakeCounter : 40|4@1+ (1,0) [0|15] "" Tester',
		' SG_ BrakeCrc : 24|16@1+ (1,0) [0|65535] "" Tester\n SG_ BrakeCounter : 40|8@1+ (1,0) [0|255] "" Tester').replace('BA_ "E2EProfile" BO_ 769 "P01";',
		'BA_ "E2EProfile" BO_ 769 "PROFILE_05";')
}

// #305: a frame the DBC declares Profile 5 is stamped and checked by Profile 5, at its header
fn test_a_profile_5_frame_is_stamped_and_checked_as_profile_5() {
	code, out, glue := overspeed_with_dbc('p05', fn (src string) string {
		return src.replace('e2e  = { data_id = 0x10, crc_pos = 1, counter_pos = 2 }', '')
	}, p05_dbc)
	assert code == 0, out
	assert glue.contains('protect_p05(&tx_lamp_frame.data[0], int(lamp_frame_dlc), u16(0x10), 1)'), glue
	assert glue.contains('check_p05(&rx.data[0], int(brake_status_dlc), u16(0x44), 3)'), glue
	assert !glue.contains('e2e_tx_lamp_frame.protect(') && !glue.contains('rxm_brake_status.e2e.check('), 'no Profile 1 call is left'
}

// the [[frame]].e2e table states Profile 5 too, and its header must be whole
fn test_a_frame_table_states_profile_5() {
	dbc := fn (dbc string) string {
		return dbc.replace('BO_ 272 LampFrame: 3 SUT', 'BO_ 272 LampFrame: 4 SUT')
	}
	code, out, glue := overspeed_with_dbc('p05tbl', fn (src string) string {
		return src.replace('e2e  = { data_id = 0x10, crc_pos = 1, counter_pos = 2 }', 'e2e  = { profile = "P05", data_id = 0x10, crc_pos = 1, counter_pos = 3 }')
	}, dbc)
	assert code == 0, out
	assert glue.contains('protect_p05(&tx_lamp_frame.data[0], int(lamp_frame_dlc), u16(0x10), 1)'), glue
	// a header that does not fit the frame is refused
	code2, out2, _ := overspeed_with('p05short', fn (src string) string {
		return src.replace('e2e  = { data_id = 0x10, crc_pos = 1, counter_pos = 2 }', 'e2e  = { profile = "P05", data_id = 0x10, crc_pos = 1, counter_pos = 3 }')
	})
	assert code2 != 0
	assert out2.contains('the Profile 5 header (crc_pos=1, counter_pos=3) must be 3 bytes within dlc=3'), out2
}

// REQ-E2E-004 on Profile 5: a received frame SecOC authenticates is checked with SecOC's bytes
// left out of the CRC, and SecOC's fields may not overlap the 2-byte CRC
fn test_a_profile_5_frame_composes_with_secoc() {
	mut m := Model{}
	m.frames.rx_timeout_us['brake'] = 300_000
	m.frames.e2e_on['brake'] = true
	m.frames.e2e_profile['brake'] = 'autosar_p05'
	m.frames.secoc_on['brake'] = true
	m.frames.frame_bus['brake'] = 'can0'
	m.frames.e2e_timeout_us['brake'] = 300_000
	m.frames.e2e_id['brake'] = 0x44
	m.frames.e2e_crc['brake'] = 3
	m.frames.e2e_ctr['brake'] = 5
	m.frames.secoc_fresh['brake'] = 1
	m.frames.secoc_mac['brake'] = 6
	m.frames.secoc_maclen['brake'] = 2
	meth, args := m.frames.e2e_call('brake', 'check', true)
	assert meth == 'check_p05_ex' && args == '3, 1, 1, 6, 2'
	pm, pa := m.frames.e2e_call('brake', 'protect', false)
	assert pm == 'protect_p05' && pa == '3'
	assert m.frames.e2e_bits('brake') == [[24, 40], [40, 48]]
	// Profile 1's spelling is what it always was
	m.frames.e2e_profile['brake'] = 'autosar_p01'
	m.frames.e2e_ctr['brake'] = 4
	meth1, args1 := m.frames.e2e_call('brake', 'check', true)
	assert meth1 == 'check_ex' && args1 == '3, 4, 1, 1, 6, 2'
	assert m.frames.e2e_bits('brake') == [[24, 32], [32, 36]]
}
