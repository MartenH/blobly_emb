module main

// @verifies REQ-INV-006
// The wide-remote-signal emitters on a hand-built model (the bench demo deliberately
// carries no wide signal until the H755 tear re-run signs the mechanism off, so this
// is what executes the wide paths in CI). The MECHANISM (xioc_n) is tear-tested in
// tools/xioc; here we pin the generator contract: the xcore_gen.h defines + budget guard,
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
		xcore_names:    ['M4Wide', 'M4Pair']
		xcore_idx:      {
			'M4Pair': 0
		}
		xcore_xw_off:   {
			'M4Wide': 0
		}
		// 32 B header + 4 slots x (1 seq + 3 lanes) u32s = 96 -> line-rounded
		xcore_xw_total: 96
	}
}

fn test_xcore_gen_h_wide_defines_and_budget_guard() {
	h := xcore_gen_h(wide_model()).join('\n')
	// the pair contract is untouched: slot define + count exclude wide signals
	assert h.contains('#define XCORE_SLOT_M4_PAIR 0')
	assert h.contains('#define XCORE_GEN_SLOTS 1')
	assert !h.contains('XCORE_SLOT_M4_WIDE')
	// the wide contract: per-signal offset + lane count, total, and the budget #error
	assert h.contains('#define XCORE_XW_M4_WIDE_OFF 0u')
	assert h.contains('#define XCORE_XW_M4_WIDE_WORDS 3u')
	assert h.contains('#define XCORE_XW_TOTAL 96u')
	assert h.contains('#if defined(XCORE_XW_MAX) && (XCORE_XW_TOTAL > XCORE_XW_MAX)')
	assert h.contains('#error')
}

fn test_wide_drain_polls_and_lean_encodes_every_lane() {
	g := xcore_produce_drain(wide_model()).join('\n')
	// wide: stateless C reader, caller-owned seq + lane buffer, one u32 lane per 4 bytes
	assert g.contains('C.xcore_poll_n(u32(0), 3, &xcore_m4_wide_seq, &xcore_m4_wide_lanes[0])')
	// freshness is consumed LAST: pacing + readiness precede the poll, else an
	// off-cycle fresh value is eaten and never transmitted (codex #211 r3)
	assert g.contains("C.xcore_layout_ok() != 0 && t1 - xcore_m4_wide_last >= u64(100000) && ch.tx_ready()")
	assert g.contains('xcore_txf.len = 12')
	assert g.contains('xcore_txf.data[0] = u8(xcore_m4_wide_lanes[0])')
	assert g.contains('xcore_txf.data[7] = u8(xcore_m4_wide_lanes[1] >> 24)')
	assert g.contains('xcore_txf.data[11] = u8(xcore_m4_wide_lanes[2] >> 24)')
	// pair emission rides along unchanged in the same drain
	assert g.contains('C.xcore_poll(0, &xcore_m4_pair_a, &xcore_m4_pair_b)')
	assert g.contains("C.xcore_layout_ok() != 0 && t1 - xcore_m4_pair_last >= u64(100000) && ch.tx_ready()")
}

fn test_wide_comm_locals_declare_seq_and_lane_buffer() {
	l := xcore_comm_locals(wide_model()).join('\n')
	assert l.contains('mut xcore_m4_wide_seq := u32(0)')
	assert l.contains('mut xcore_m4_wide_lanes := [3]u32{}')
	// the pair keeps its {a,b} locals
	assert l.contains('mut xcore_m4_pair_a := u32(0)')
}

fn test_layout_id_covers_the_whole_map() {
	m := wide_model()
	h := xcore_gen_h(m).join('\n')
	assert h.contains('#define XCORE_LAYOUT_ID 0x')
	// the id must change when ANY slot moves — the stale-image cross-talk guard
	mut m2 := wide_model()
	m2.xcore_xw_off = {
		'M4Wide': 32
	}
	assert xcore_layout_id(m) != xcore_layout_id(m2)
	// and be deterministic for the same map
	assert xcore_layout_id(m) == xcore_layout_id(wide_model())
}

fn test_wide_c_decl_and_manifest_row() {
	assert xcore_c_decls(wide_model()).join('\n').contains('fn C.xcore_poll_n(u32, u32, &u32, &u32) int')
	man := xcore_manifest(wide_model()).join('\n')
	assert man.contains('M4Wide,xw+0,0x300')
	assert man.contains('M4Pair,0,0x301')
}
