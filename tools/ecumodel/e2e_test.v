module ecumodel

import toml
import tools.candb

const e2e_dbc = 'BO_ 769 BrakeStatus: 6 Brake
 SG_ BrakeCrc : 32|8@1+ (1,0) [0|255] "" X
 SG_ BrakeCounter : 40|4@1+ (1,0) [0|15] "" X
 SG_ Wide : 0|16@1+ (1,0) [0|65535] "" X
BA_ "E2ECounterSignal" BO_ 769 "BrakeCounter";
BA_ "E2ECrcSignal" BO_ 769 "BrakeCrc";
BA_ "E2EProfile" BO_ 769 "P01";
BA_ "E2EDataId" BO_ 769 68;
'

fn brake(extra string) candb.Message {
	return (candb.parse_dbc(e2e_dbc + extra) or { panic(err) }).messages[0]
}

fn e2e_table(src string) map[string]toml.Any {
	return (toml.parse_text('e2e = ${src}') or { panic(err) }).value('e2e').as_map()
}

fn test_the_dbc_declares_the_layout_when_the_frame_says_nothing() {
	e, on := resolve_frame_e2e('brake_status', false, map[string]toml.Any{}, brake(''))!
	assert on
	assert e == FrameE2e{
		data_id:     0x44
		crc_pos:     4
		counter_pos: 5
	}
	// a table carrying only the E2E timeout takes the whole layout from the DBC
	e2, _ := resolve_frame_e2e('brake_status', true, e2e_table('{ timeout_ms = 300 }'), brake(''))!
	assert e2.data_id == e.data_id && e2.crc_pos == e.crc_pos && e2.counter_pos == e.counter_pos
	assert e2.timeout_ms == 300
}

fn test_an_override_that_contradicts_the_dbc_is_refused_unless_deliberate() {
	resolve_frame_e2e('brake_status', true, e2e_table('{ crc_pos = 3 }'), brake('')) or {
		assert err.msg().contains('contradicts the DBC')
		e, _ := resolve_frame_e2e('brake_status', true, e2e_table('{ crc_pos = 3, deviates_from_dbc = true }'),
			brake(''))!
		assert e.crc_pos == 3 && e.counter_pos == 5 && e.data_id == 0x44
		// an agreeing override is fine
		resolve_frame_e2e('brake_status', true, e2e_table('{ data_id = 0x44 }'), brake(''))!
		return
	}
	assert false, 'a contradicting override was accepted'
}

fn test_deviating_from_nothing_is_refused() {
	plain := (candb.parse_dbc('BO_ 1 A: 8 X\n SG_ S : 0|8@1+ (1,0) [0|255] "" X\n') or { panic(err) }).messages[0]
	resolve_frame_e2e('a', true, e2e_table('{ data_id = 1, crc_pos = 0, counter_pos = 1, deviates_from_dbc = true }'),
		plain) or {
		assert err.msg().contains('declares no E2E')
		return
	}
	assert false
}

fn test_a_declaration_comm_e2e_cannot_stamp_is_refused() {
	for extra, why in {
		'BA_ "E2EProfile" BO_ 769 "crc8";':          'only P01'
		'BA_ "E2EDataId" BO_ 769 70000;':            '0..0xFFFF'
		'BA_ "E2EDataId" BO_ 769 x;':                'not a Data ID'
		'BA_ "E2ECrcSignal" BO_ 769 "Wide";':        'E2ECrcSignal'
		'BA_ "E2ECounterSignal" BO_ 769 "Missing";': 'not a signal'
		'BA_ "E2ECounterSignal" BO_ 769 "BrakeCrc";': 'E2ECounterSignal'
	} {
		dbc_e2e(brake(extra)) or {
			assert err.msg().contains(why), '${extra}: ${err.msg()}'
			continue
		}
		assert false, '${extra} was accepted'
	}
}

fn test_without_a_dbc_declaration_the_table_must_be_complete() {
	plain := (candb.parse_dbc('BO_ 1 A: 8 X\n SG_ S : 0|8@1+ (1,0) [0|255] "" X\n') or { panic(err) }).messages[0]
	resolve_frame_e2e('a', true, e2e_table('{ data_id = 1, crc_pos = 2 }'), plain) or {
		assert err.msg().contains('no counter_pos'), err.msg()
		resolve_frame_e2e('a', true, e2e_table('{ timeout_ms = 300 }'), none) or {
			assert err.msg().contains('no data_id, crc_pos, counter_pos')
			return
		}
	}
	assert false, 'a partial table with nothing to fill it from was accepted'
}

fn test_a_declaration_comm_e2e_cannot_stamp_may_be_replaced_whole_and_on_purpose() {
	bad := brake('BA_ "E2EProfile" BO_ 769 "crc8";')
	resolve_frame_e2e('brake_status', true, e2e_table('{ crc_pos = 4, counter_pos = 5, data_id = 0x44 }'),
		bad) or {
		assert err.msg().contains('deviates_from_dbc')
		e, _ := resolve_frame_e2e('brake_status', true, e2e_table('{ crc_pos = 4, counter_pos = 5, data_id = 0x44, deviates_from_dbc = true }'),
			bad)!
		assert e.crc_pos == 4
		return
	}
	assert false
}

fn test_a_multiplexed_field_signal_is_refused() {
	m := (candb.parse_dbc('BO_ 769 F: 8 X
 SG_ Sel M : 0|8@1+ (1,0) [0|255] "" X
 SG_ Crc m1 : 32|8@1+ (1,0) [0|255] "" X
 SG_ Ctr : 40|4@1+ (1,0) [0|15] "" X
BA_ "E2ECounterSignal" BO_ 769 "Ctr";
BA_ "E2ECrcSignal" BO_ 769 "Crc";
BA_ "E2EProfile" BO_ 769 "P01";
BA_ "E2EDataId" BO_ 769 1;
') or { panic(err) }).messages[0]
	dbc_e2e(m) or {
		assert err.msg().contains('multiplexed')
		return
	}
	assert false
}

fn test_the_dbc_timeout_is_the_frames_unless_the_table_deviates() {
	m := brake('BA_ "E2ETimeout" BO_ 769 300;')
	e, _ := resolve_frame_e2e('brake_status', false, map[string]toml.Any{}, m)!
	assert e.timeout_ms == 300
	resolve_frame_e2e('brake_status', true, e2e_table('{ timeout_ms = 200 }'), m) or {
		assert err.msg().contains("contradicts the DBC's E2ETimeout")
		d, _ := resolve_frame_e2e('brake_status', true, e2e_table('{ timeout_ms = 200, deviates_from_dbc = true }'),
			m)!
		assert d.timeout_ms == 200
		// a DBC without one leaves the table free to set it
		f, _ := resolve_frame_e2e('brake_status', true, e2e_table('{ timeout_ms = 200 }'), brake(''))!
		assert f.timeout_ms == 200
		return
	}
	assert false, 'a contradicting timeout was accepted'
}
