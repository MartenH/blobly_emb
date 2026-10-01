module candb

// @verifies REQ-TOPO-003

// A standard frame (id 0x100) and an extended frame (stripped id 0x100, raw
// 0x80000100) share a numeric id but are distinct on the wire. Their per-frame
// attributes (GenMsgCycleTime, signal comment) must attach to the RIGHT frame:
// the attribute index is keyed by (id, ext), not the stripped id alone (which
// let the later BO_ overwrite the earlier and mis-attach both).
fn test_std_and_ext_same_stripped_id_keep_own_attributes() {
	dbc := 'BO_ 256 StdFrame: 8 Gw
 SG_ StdSig : 0|8@1+ (1,0) [0|255] "" Sink

BO_ 2147483904 ExtFrame: 8 Gw
 SG_ ExtSig : 0|8@1+ (1,0) [0|255] "" Sink

BA_ "GenMsgCycleTime" BO_ 256 20;
BA_ "GenMsgCycleTime" BO_ 2147483904 100;
CM_ SG_ 256 StdSig "standard signal";
CM_ SG_ 2147483904 ExtSig "extended signal";
'
	db := parse_dbc(dbc) or { panic(err) }
	mut std := Message{}
	mut ext := Message{}
	for m in db.messages {
		if m.name == 'StdFrame' {
			std = m
		}
		if m.name == 'ExtFrame' {
			ext = m
		}
	}
	assert std.id == 0x100 && !std.ext
	assert ext.id == 0x100 && ext.ext
	// each frame keeps its OWN cycle time (the bug attached both to the later BO_)
	assert std.cycle_ms == 20, 'std cycle_ms=${std.cycle_ms} (want 20)'
	assert ext.cycle_ms == 100, 'ext cycle_ms=${ext.cycle_ms} (want 100)'
	// and its OWN signal comment
	assert std.signals[0].desc == 'standard signal'
	assert ext.signals[0].desc == 'extended signal'

	// lookup_frame resolves by (id, width): a received extended frame must not select
	// the standard layout, nor vice versa.
	s := db.lookup_frame(0x100, false) or { panic('std lookup_frame miss') }
	assert s.name == 'StdFrame', 'lookup_frame(0x100,false)=${s.name}'
	e := db.lookup_frame(0x100, true) or { panic('ext lookup_frame miss') }
	assert e.name == 'ExtFrame', 'lookup_frame(0x100,true)=${e.name}'
}

// blobly_net#271: the E2E contract's four attributes, parsed as blobly_net's candb parses them
// (the spellings its writer and cmd/arxml2dbc emit).
fn test_e2e_contract_attributes() {
	db := parse_dbc('VERSION ""
BU_: Brake
BO_ 769 BrakeStatus: 6 Brake
 SG_ BrakePressure : 0|16@1+ (0.1,0) [0|6553.5] "kPa" Vector__XXX
 SG_ BrakeCrc : 32|8@1+ (1,0) [0|255] "" Vector__XXX
 SG_ BrakeCounter : 40|4@1+ (1,0) [0|15] "" Vector__XXX
BO_ 770 Other: 8 Brake
 SG_ X : 0|8@1+ (1,0) [0|255] "" Vector__XXX
BO_ 2147483905 ExtFrame: 8 Brake
 SG_ C : 0|8@1+ (1,0) [0|255] "" Vector__XXX
BA_DEF_ BO_ "E2ECounterSignal" STRING;
BA_DEF_ BO_ "E2ECrcSignal" STRING;
BA_DEF_ BO_ "E2EProfile" STRING;
BA_DEF_ BO_ "E2EDataId" INT 0 65535;
BA_DEF_DEF_ "E2EProfile" "autosar_p01";
BA_ "E2ECounterSignal" BO_ 769 "BrakeCounter";
BA_ "E2ECrcSignal" BO_ 769 "BrakeCrc";
BA_ "E2EDataId" BO_ 769 68;
BA_ "E2EDataId" BO_ 770 bogus;
BA_ "E2ECrcSignal" BO_ 2147483905 "C";
')!
	bs := db.messages[0].e2e
	assert bs.counter == 'BrakeCounter' && bs.crc == 'BrakeCrc'
	assert bs.profile == 'autosar_p01', 'the file-wide default fills a declared message'
	assert bs.has_data_id && bs.data_id == 68
	o := db.messages[1].e2e
	assert !o.has_data_id && o.bad_data_id == 'bogus', 'a Data ID that is not one is kept, not read as absent'
	assert db.messages[2].e2e.crc == 'C', 'an extended id resolves through its EFF bit'
	plain := parse_dbc('BO_ 1 A: 8 X\n SG_ S : 0|8@1+ (1,0) [0|255] "" X\nBA_DEF_DEF_ "E2EProfile" "autosar_p01";\n')!
	assert !plain.messages[0].e2e.declared(), 'a default alone protects nothing'
}

// docs/dbc_attributes.md (blobly_net): Profile 1's three spellings are one profile; E2ETimeout
// is ms, a per-message 0 is "none" and not overridden by a default, a default of 0 states
// nothing, and a timeout alone declares no protection; an empty value is malformed, not absent;
// a Data ID never comes from a default
fn test_e2e_spellings_and_timeout_rules() {
	for v in ['P01', 'PROFILE_01', 'autosar_p01'] {
		db := parse_dbc('BO_ 1 A: 8 N\n SG_ S : 0|8@1+ (1,0) [0|255] "" X\nBA_ "E2EProfile" BO_ 1 "${v}";\n')!
		assert db.messages[0].e2e.profile == 'autosar_p01', v
	}
	db := parse_dbc('BO_ 1 A: 8 N
 SG_ C : 0|8@1+ (1,0) [0|255] "" X
BO_ 2 B: 8 N
 SG_ C : 0|8@1+ (1,0) [0|255] "" X
BO_ 3 T: 8 N
 SG_ C : 0|8@1+ (1,0) [0|255] "" X
BO_ 4 E: 8 N
 SG_ C : 0|8@1+ (1,0) [0|255] "" X
BA_DEF_DEF_ "E2ETimeout" 500;
BA_DEF_DEF_ "E2EDataId" 7;
BA_ "E2ECrcSignal" BO_ 1 "C";
BA_ "E2ETimeout" BO_ 1 0;
BA_ "E2ECrcSignal" BO_ 2 "C";
BA_ "E2ETimeout" BO_ 3 300;
BA_ "E2EDataId" BO_ 4 ;
')!
	a := db.messages[0].e2e
	assert a.has_timeout && a.timeout_ms == 0, 'an explicit 0 was overridden by the default'
	b := db.messages[1].e2e
	assert b.has_timeout && b.timeout_ms == 500
	assert !b.has_data_id, 'a Data ID came from a default'
	t := db.messages[2].e2e
	assert !t.declared() && t.timeout_ms == 300, 'a timeout alone declares no protection'
	assert db.messages[3].e2e.bad_data_id == '(empty)'
}
