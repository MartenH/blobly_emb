module main

import os

// E2E from the DBC (blobly_net#271): a frame the DBC protects needs no [[frame]].e2e, and on an
// ECU with one CAN bus no [[frame]] at all. Runs the real generator on examples/overspeed, whose
// BrakeStatus layout lives in its bus.dbc — a refusal is a panic, which cannot be caught in-process.

fn e2e_loom2v_bin() string {
	bin := os.join_path(os.temp_dir(), 'loom2v_e2e_dbc_${os.getpid()}')
	if !os.exists(bin) {
		r := os.execute('${@VEXE} -enable-globals -o ${bin} ${os.join_path(@VMODROOT, 'tools',
			'loom2v')}')
		assert r.exit_code == 0, r.output
	}
	return bin
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

const brake_block = '[[frame]]
name = "BrakeStatus"'

// cut removes the table starting at `head` up to the next `[[<kind>]]`.
fn cut(src string, head string, kind string) string {
	i := src.index(head) or { panic('overspeed lost `${head}` — update this test') }
	j := src.index_after('[[${kind}]]', i + 1) or { panic('`${head}` is not followed by a [[${kind}]]') }
	return src[..i] + src[j..]
}

// without_brake_frame drops BrakeStatus's [[frame]], and with it the E2E deadline its timeout
// fault needs (the DBC has no home for a deadline), so the fault goes too.
fn without_brake_frame(src string) string {
	return cut(cut(src, brake_block, 'frame'), '[[fault]]\nname   = "BrakeMsgTimeout"', 'fault')
}

fn test_a_received_frame_only_the_dbc_protects_still_needs_its_deadline() {
	// the DBC has no home for E2E's own sender-loss timeout (REQ-E2E-002), so a received
	// protected frame keeps a [[frame]] for it
	code, out, _ := overspeed_with('nofr', without_brake_frame)
	assert code != 0
	assert out.contains('"brake_status" is E2E-protected and received, but its e2e has no timeout_ms'), out
}

// lamp_dbc gives LampFrame CRC and counter signals and declares its E2E in the DBC.
fn lamp_dbc(dbc string) string {
	return dbc.replace(' SG_ WarnLamp : 0|1@1+ (1,0) [0|1] "" Tester',
		' SG_ WarnLamp : 0|1@1+ (1,0) [0|1] "" Tester\n SG_ LampCrc : 8|8@1+ (1,0) [0|255] "" Tester\n SG_ LampCounter : 16|4@1+ (1,0) [0|15] "" Tester') +
		'\nBA_ "E2ECounterSignal" BO_ 272 "LampCounter";\nBA_ "E2ECrcSignal" BO_ 272 "LampCrc";\nBA_ "E2EProfile" BO_ 272 "autosar_p01";\nBA_ "E2EDataId" BO_ 272 16;\n'
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
	code, out, _ := overspeed_with('contra', fn (src string) string {
		return src.replace('e2e  = { timeout_ms = 300 }', 'e2e  = { timeout_ms = 300, crc_pos = 3 }')
	})
	assert code != 0
	assert out.contains('contradicts the DBC'), out
}
