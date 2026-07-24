module main

// @verifies REQ-INV-006
// The wide-remote-signal emitters on a hand-built model (the bench demo deliberately
// carries no wide signal until the H755 tear re-run signs the mechanism off, so this
// is what executes the wide paths in CI). The MECHANISM (xioc_n) is tear-tested in
// tools/xioc; here we pin the generator contract: the duo_gen.h defines + budget guard,
// the satellite lane order, and the owner drain's poll/encode shape.

fn wide_model() Model {
	mut sig_of := map[string]SigInfo{}
	sig_of['M4Wide'] = SigInfo{
		name:     'M4Wide'
		from:     'm4'
		to:       'can0'
		external: true
		remote:   true
		wide:     true
		fields:   [
			SigField{
				name: 'n'
				typ:  'u32'
			},
			SigField{
				name: 'lo'
				typ:  'u16'
			},
			SigField{
				name: 'ok'
				typ:  'bool'
			},
		]
		dbc_msg:  'm4_wide_frame'
		dbc_id:   0x300
		dbc_dlc:  12
	}
	sig_of['M4Pair'] = SigInfo{
		name:     'M4Pair'
		from:     'm4'
		to:       'can0'
		external: true
		remote:   true
		fields:   [
			SigField{
				name: 'a'
				typ:  'u32'
			},
			SigField{
				name: 'b'
				typ:  'u32'
			},
		]
		dbc_msg:  'm4_pair_frame'
		dbc_id:   0x301
		dbc_dlc:  8
	}
	return Model{
		sig_of:       sig_of
		duo_names:    ['M4Wide', 'M4Pair']
		duo_idx:      {
			'M4Pair': 0
		}
		duo_xw_off:   {
			'M4Wide': 0
		}
		// 32 B header + 4 slots x (1 seq + 3 lanes) u32s = 96 -> line-rounded
		duo_xw_total: 96
	}
}

fn test_duo_gen_h_wide_defines_and_budget_guard() {
	h := duo_gen_h(wide_model()).join('\n')
	// the pair contract is untouched: slot define + count exclude wide signals
	assert h.contains('#define DUO_SLOT_M4_PAIR 0')
	assert h.contains('#define DUO_GEN_SLOTS 1')
	assert !h.contains('DUO_SLOT_M4_WIDE')
	// the wide contract: per-signal offset + lane count, total, and the budget #error
	assert h.contains('#define DUO_XW_M4_WIDE_OFF 0u')
	assert h.contains('#define DUO_XW_M4_WIDE_WORDS 3u')
	assert h.contains('#define DUO_XW_TOTAL 96u')
	assert h.contains('#if defined(DUO_XW_MAX) && (DUO_XW_TOTAL > DUO_XW_MAX)')
	assert h.contains('#error')
}

fn test_wide_drain_polls_and_lean_encodes_every_lane() {
	g := duo_produce_drain(wide_model()).join('\n')
	// wide: stateless C reader, caller-owned seq + lane buffer, one u32 lane per 4 bytes
	assert g.contains('C.duo_poll_n(u32(0), 3, &duo_m4_wide_seq, &duo_m4_wide_lanes[0])')
	assert g.contains('duo_txf.len = 12')
	assert g.contains('duo_txf.data[0] = u8(duo_m4_wide_lanes[0])')
	assert g.contains('duo_txf.data[7] = u8(duo_m4_wide_lanes[1] >> 24)')
	assert g.contains('duo_txf.data[11] = u8(duo_m4_wide_lanes[2] >> 24)')
	// pair emission rides along unchanged in the same drain
	assert g.contains('C.duo_poll(0, &duo_m4_pair_a, &duo_m4_pair_b)')
}

fn test_wide_comm_locals_declare_seq_and_lane_buffer() {
	l := duo_comm_locals(wide_model()).join('\n')
	assert l.contains('mut duo_m4_wide_seq := u32(0)')
	assert l.contains('mut duo_m4_wide_lanes := [3]u32{}')
	// the pair keeps its {a,b} locals
	assert l.contains('mut duo_m4_pair_a := u32(0)')
}

fn test_wide_c_decl_and_manifest_row() {
	assert duo_c_decls(wide_model()).join('\n').contains('fn C.duo_poll_n(u32, u32, &u32, &u32) int')
	man := duo_manifest(wide_model()).join('\n')
	assert man.contains('M4Wide,xw+0,0x300')
	assert man.contains('M4Pair,0,0x301')
}
