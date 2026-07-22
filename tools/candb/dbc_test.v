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
}
