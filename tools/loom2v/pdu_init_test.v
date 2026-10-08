module main

import os
import time
import tools.candb

// @verifies REQ-COM-011
// A PDU goes out before every one of its signals has been published, so each emitter starts the frame
// at its initial payload (pdu_init_lines: candb init_payload — GenSigStartValue, else the in-range
// value nearest 0) rather than at raw 0, and an initial value is never counted as a saturation: the
// host bridge, the target's local producers and its satellite lanes.

const pi_bin = os.join_path(os.temp_dir(), 'loom2v_pdu_init_${os.getpid()}_${time.now().unix_nano()}')

fn testsuite_begin() {
	r := os.execute('${@VEXE} -enable-globals -o ${pi_bin} ${os.join_path(@VMODROOT, 'tools',
		'loom2v')}')
	assert r.exit_code == 0, r.output
}

fn testsuite_end() {
	os.rm(pi_bin) or {}
}

// pi_generate runs loom2v on `ecu` and `dbc` (texts); returns the exit code, the output and the glue.
fn pi_generate(name string, ecu string, dbc string) (int, string, string) {
	tmp := os.join_path(os.temp_dir(), 'pdu_init_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	os.mkdir_all(tmp) or { panic(err) }
	ecup := os.join_path(tmp, 'ecu.toml')
	dbcp := os.join_path(tmp, 'bus.dbc')
	os.write_file(ecup, ecu) or { panic(err) }
	os.write_file(dbcp, dbc) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${pi_bin} ${ecup} ${dbcp} ${os.join_path(tmp, 'sig.v')} ' +
		'${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }
}

fn read(p ...string) string {
	return os.read_file(os.join_path(@VMODROOT, ...p)) or { panic(err) }
}

// pi_one_thread: the threadx_node fixture's FBs on its first thread (rx_target_test.v's rt_one_thread)
fn pi_one_thread(src string) string {
	mut s := src
	for t in ['load_mid', 'ctrl_slow'] {
		at := s.index('  [[partition.thread]]\n  name     = "${t}"') or { panic('no thread ${t}') }
		end := s.index_after('\n\n', at) or { panic('no end of thread ${t}') }
		s = s[..at] + s[end + 2..]
		s = s.replace('thread    = "${t}"', 'thread    = "load_fast"')
	}
	return s
}

// overspeed's LampFrame: WarnLamp is published, LampLevel ([10|20]) and LampMode never are
fn lamp_dbc(attrs string) string {
	return read('examples', 'overspeed', 'bus.dbc').replace('BO_ 272 LampFrame: 3 SUT\n SG_ WarnLamp : 0|1@1+ (1,0) [0|1] "" Tester',
		'BO_ 272 LampFrame: 3 SUT\n SG_ WarnLamp : 0|1@1+ (1,0) [0|1] "" Tester\n SG_ LampLevel : 8|8@1+ (1,0) [10|20] "" Tester\n SG_ LampMode : 16|8@1+ (1,0) [0|255] "" Tester') +
		attrs
}

// the host bridge: the frame starts at its initial payload, then each published field is written over it
fn test_the_host_bridge_starts_a_frame_at_its_initial_payload() {
	ecu := read('examples', 'overspeed', 'ecu.toml')
	code, out, glue := pi_generate('host', ecu, lamp_dbc('BA_DEF_ SG_ "GenSigStartValue" INT 0 255;\nBA_ "GenSigStartValue" SG_ 272 LampMode 7;\n'))
	assert code == 0, out
	at := glue.index('mut tx_lamp_frame := can.Frame{') or { panic(glue) }
	body := glue[at..]
	assert body.contains('\ttx_lamp_frame.data[0] = u8(0x00)\n\ttx_lamp_frame.data[1] = u8(0x0a)\n\ttx_lamp_frame.data[2] = u8(0x07)\n'), body
	init := body.index('tx_lamp_frame.data[1] = u8(0x0a)') or { -1 }
	set := body.index('lamp_frame_warn_lamp_set(mut tx_lamp_frame.data') or { -1 }
	assert init >= 0 && init < set, 'the initial payload is written before the published field'
	// a field never published is not a saturation: only `_set` counts
	assert body.count('tx_lamp_frame_sat++') == 1
}

// a start value outside the range is refused at generation, naming the signal and the file
fn test_a_start_value_outside_the_range_is_refused() {
	ecu := read('examples', 'overspeed', 'ecu.toml')
	code, out, _ := pi_generate('refuse', ecu, lamp_dbc('BA_DEF_ SG_ "GenSigStartValue" INT 0 255;\nBA_ "GenSigStartValue" SG_ 272 LampLevel 30;\n'))
	assert code != 0
	assert out.contains('message "LampFrame": signal "LampLevel": GenSigStartValue 30 is outside its raw range 10.0..20.0'), out
}

// the target's local producer: the frame starts at its initial payload — a lane no field fills
// included — and until the FB's first publish nothing is encoded, so nothing is counted
fn test_the_target_producer_sends_the_initial_payload_until_the_first_publish() {
	ecu := pi_one_thread(read('tools', 'loom2v', 'testdata', 'threadx_node', 'ecu.toml'))
	dbc := read('tools', 'loom2v', 'testdata', 'threadx_node', 'bus.dbc').replace('BO_ 512 WorkloadFrame: 4 SUT\n SG_ Workload : 0|32@1+ (1,0) [0|4294967295] "" Tester',
		'BO_ 512 WorkloadFrame: 8 SUT\n SG_ Workload : 0|32@1+ (1,0) [5|4294967295] "" Tester\n SG_ Spare : 32|32@1+ (1,0) [100|200] "" Tester')
	code, out, glue := pi_generate('target', ecu, dbc)
	assert code == 0, out
	at := glue.index('mut tf := can.Frame{') or { panic(glue) }
	body := glue[at..glue.index_after('if ch.send(tf) {', at) or { panic(glue) }]
	assert body.contains('\t\t\ttf.data[0] = u8(0x05)\n\t\t\ttf.data[1] = u8(0x00)'), body
	assert body.contains('\t\t\ttf.data[4] = u8(0x64)\n\t\t\ttf.data[5] = u8(0x00)\n\t\t\ttf.data[6] = u8(0x00)\n\t\t\ttf.data[7] = u8(0x00)'), body
	gate := body.index('if C.ioc_get_ever(') or { panic(body) }
	assert body.index('tf.data[4] = u8(0x64)') or { -1 } < gate
	assert body[gate..].contains('tf_raw0, tf_raw0_sat := com.encode_raw(')
	assert !body.contains('C.ioc_get('), 'the producer reads its cell only through the ever gate'
	assert glue.contains('fn C.ioc_get_ever(int, &u32, &u32) int')
}

// the satellite lanes: the shared frame starts at the message's initial payload before its lanes
fn test_a_satellite_lane_frame_starts_at_its_initial_payload() {
	mut sig_of := map[string]SigInfo{}
	sig_of['M4Pair'] = SigInfo{
		name:      'M4Pair'
		from:      'm4'
		to:        'can0'
		external:  true
		remote:    true
		fields:    [SigField{
			name: 'a'
			typ:  'u32'
		}]
		dbc_msg:   'm4_pair_frame'
		dbc_id:    0x301
		dbc_dlc:   8
		dbc_lanes: [candb.Signal{
			name:   'PairA'
			length: 32
		}]
		dbc_init:  [u8(0), 0, 0, 0, 0x2a, 0, 0, 0]
	}
	g := xcore_produce_drain(Model{
		sig_of:      sig_of
		xcore_names: ['M4Pair']
		xcore_idx:   {
			'M4Pair': 0
		}
	}).join('\n')
	init := g.index('\t\t\txcore_txf.data[4] = u8(0x2a)') or { panic(g) }
	assert g.contains('\t\t\txcore_txf.data[7] = u8(0x00)'), 'every byte of the DLC: the frame is reused'
	assert init < (g.index('xcore_txf_raw0, xcore_txf_raw0_sat := com.encode_raw(') or { -1 })
	assert pdu_init_lines(SigInfo{}, 'f', '') == []string{}
}
