module main

// @verifies REQ-INV-006
// Owner -> satellite channels (gen_xdown.v) on hand-built models: which signals get a down channel
// (derived from the FBs that READ them), every refusal, the lane encode for each field type, the
// layout id, and the shapes the owner and satellite images emit. The C mechanism under them is
// tested in tools/xioc (xcore_down_test.v).

fn sf(name string, typ string) SigField {
	return SigField{
		name: name
		typ:  typ
	}
}

// a node with an owner partition `ctl` (core 0, thread `fast`) and a generated satellite `sat`
// (core 1, threads `model` and `slow`), plus a hand-written satellite `hand` (core 2, thread `hw`)
fn two_core_parts() PartMap {
	return PartMap{
		core_of:     {
			'ctl':  0
			'sat':  1
			'hand': 2
		}
		thread_part: {
			'fast':  'ctl'
			'model': 'sat'
			'slow':  'sat'
			'hw':    'hand'
		}
		external:    {
			'ctl':  false
			'sat':  true
			'hand': true
		}
		image:       {
			'sat': 'nodes/sat'
		}
	}
}

fn rw(name string, part string, thr string, reads []string, writes []string) FbRW {
	return FbRW{
		name:   name
		part:   part
		thread: thr
		reads:  reads
		writes: writes
	}
}

fn down_sigs() map[string]SigInfo {
	return {
		'PtState': SigInfo{
			name:   'PtState'
			from:   'ctl'
			to:     'sat'
			fields: [sf('seq', 'u32'), sf('inv', 'u32')]
		}
		'Cmd':     SigInfo{
			name:      'Cmd'
			from:      'can0'
			to:        'sat'
			external:  true
			rx:        true
			bus:       'can0'
			dbc_msg:   'CmdFrame'
			dbc_id:    0x124
			val_field: 'cmd'
			val_type:  'u32'
			fields:    [sf('cmd', 'u32')]
		}
		'Speed':   SigInfo{
			name:       'Speed'
			from:       'can0'
			to:         'ctl'
			external:   true
			rx:         true
			bus:        'can0'
			dbc_msg:    'SpeedFrame'
			dbc_id:     0x125
			val_field:  'kph'
			val_type:   'u16'
			has_status: true
			fields:     [sf('kph', 'u16'), sf('status', 'RxStatus')]
		}
		'Torque':  SigInfo{
			name:   'Torque'
			from:   'sat'
			to:     'ctl'
			fields: [sf('nm', 'u32')]
		}
		'Wide':    SigInfo{
			name:   'Wide'
			from:   'ctl'
			to:     'sat'
			fields: [sf('t', 'f64'), sf('n', 'i16'), sf('ok', 'bool'), sf('g', 'f32'), sf('c', 'u64')]
		}
	}
}

const all_sigs = ['PtState', 'Cmd', 'Speed', 'Torque', 'Wide']

fn test_lane_counts_and_channel_footprint() {
	assert field_lanes('u32') == 1
	assert field_lanes('f32') == 1
	assert field_lanes('i64') == 2
	assert field_lanes('f64') == 2
	s := down_sigs()
	assert sig_lanes(s['Wide']) == 7 // f64 2 + i16 + bool + f32 + u64 2
	// xioc.h XIOC_N_BYTES: 32 + 16 * (1 + lanes), up to the 32 B line
	assert xioc_n_bytes(1) == 64
	assert xioc_n_bytes(2) == 96
	assert xioc_n_bytes(16) == 320
}

fn test_an_owner_fb_output_read_on_the_satellite_gets_a_channel() {
	fbs := [rw('Pt', 'ctl', 'fast', [], ['PtState']), rw('Dyn', 'sat', 'model', ['PtState'], [])]
	d := xdown_derive(['PtState'], down_sigs(), two_core_parts(), fbs, [], '') or { panic(err) }
	assert d.names == ['PtState']
	assert d.off['PtState'] == 0
	assert d.lanes['PtState'] == 2
	assert !d.lean['PtState']
	assert d.total == 96
}

fn test_a_lean_received_signal_rides_one_lane() {
	fbs := [rw('Dyn', 'sat', 'model', ['Cmd'], [])]
	d := xdown_derive(['Cmd'], down_sigs(), two_core_parts(), fbs, [], '') or { panic(err) }
	assert d.names == ['Cmd']
	assert d.lean['Cmd']
	assert d.lanes['Cmd'] == 1
}

fn test_a_checked_received_signal_carries_every_field_and_its_status() {
	fbs := [rw('Dyn', 'sat', 'model', ['Speed'], [])]
	d := xdown_derive(['Speed'], down_sigs(), two_core_parts(), fbs, ['SpeedFrame'], '') or {
		panic(err)
	}
	assert !d.lean['Speed']
	assert d.lanes['Speed'] == 2 // kph + status
}

fn test_readers_decide_not_the_signal_to() {
	// `to` names the owner partition, but a satellite fb reads it too: fan-out, one channel
	fbs := [rw('Pt', 'ctl', 'fast', ['Speed'], []), rw('Dyn', 'sat', 'model', ['Speed'], [])]
	d := xdown_derive(['Speed'], down_sigs(), two_core_parts(), fbs, ['SpeedFrame'], '') or {
		panic(err)
	}
	assert d.names == ['Speed']
	owner := fb_reads_owner(fbs, two_core_parts())
	assert owner['Speed'] == 1 // the owner's cell is for the owner reader alone
	// `to` names the satellite but nobody there reads it: no channel
	nobody := xdown_derive(['PtState'], down_sigs(), two_core_parts(), [
		rw('Pt', 'ctl', 'fast', [], ['PtState']),
	], [], '') or { panic(err) }
	assert nobody.names.len == 0
}

fn test_a_satellite_produced_signal_is_the_up_direction() {
	fbs := [rw('Dyn', 'sat', 'model', [], ['Torque']), rw('Pt', 'ctl', 'fast', ['Torque'], [])]
	d := xdown_derive(['Torque'], down_sigs(), two_core_parts(), fbs, [], '') or { panic(err) }
	assert d.names.len == 0
	// a satellite THREAD named as the endpoint is the same partition
	mut s := down_sigs()
	s['Torque'] = SigInfo{
		...s['Torque']
		from: 'model'
	}
	d2 := xdown_derive(['Torque'], s, two_core_parts(), [
		rw('Dyn2', 'sat', 'slow', ['Torque'], []),
	], [], '') or { panic(err) }
	assert d2.names.len == 0
}

fn test_channels_are_laid_out_in_declaration_order_on_the_line() {
	fbs := [rw('Pt', 'ctl', 'fast', [], ['PtState', 'Wide']),
		rw('Dyn', 'sat', 'model', ['PtState', 'Cmd', 'Wide'], [])]
	d := xdown_derive(all_sigs, down_sigs(), two_core_parts(), fbs, [], '') or { panic(err) }
	assert d.names == ['PtState', 'Cmd', 'Wide']
	assert d.off['PtState'] == 0
	assert d.off['Cmd'] == 96
	assert d.off['Wide'] == 96 + 64
	assert d.lanes['Wide'] == 7
	assert d.total == 96 + 64 + xioc_n_bytes(7)
	for _, o in d.off {
		assert o % 32 == 0
	}
}

fn refused(names []string, s map[string]SigInfo, fbs []FbRW, checked []string, eth string) string {
	xdown_derive(names, s, two_core_parts(), fbs, checked, eth) or { return err.msg() }
	return ''
}

fn test_a_hand_written_satellite_reader_is_refused() {
	msg := refused(['PtState'], down_sigs(), [rw('Pt', 'ctl', 'fast', [], ['PtState']),
		rw('H', 'hand', 'hw', ['PtState'], [])], [], '')
	assert msg.contains('hand-written satellite')
	assert msg.contains('"H"')
}

fn test_io_and_eth_sources_are_refused_on_the_satellite() {
	mut s := down_sigs()
	s['Btn'] = SigInfo{
		name:   'Btn'
		from:   'io'
		to:     'sat'
		io_in:  true
		fields: [sf('on', 'bool')]
	}
	s['Eth'] = SigInfo{
		name:     'Eth'
		from:     'eth0'
		to:       'sat'
		external: true
		rx:       true
		bus:      'eth0'
		fields:   [sf('v', 'u32')]
	}
	assert refused(['Btn'], s, [rw('Dyn', 'sat', 'model', ['Btn'], [])], [], '').contains('io point')
	assert refused(['Eth'], s, [rw('Dyn', 'sat', 'model', ['Eth'], [])], [], 'eth0').contains('eth bus')
}

fn test_two_owner_writer_threads_are_refused() {
	mut p := two_core_parts()
	p.thread_part['other'] = 'ctl'
	fbs := [rw('A', 'ctl', 'fast', [], ['PtState']), rw('B', 'ctl', 'other', [], ['PtState']),
		rw('Dyn', 'sat', 'model', ['PtState'], [])]
	xdown_derive(['PtState'], down_sigs(), p, fbs, [], '') or {
		assert err.msg().contains('ONE producer context')
		return
	}
	assert false
}

fn test_a_field_no_lane_carries_is_refused() {
	mut s := down_sigs()
	s['Big'] = SigInfo{
		name:   'Big'
		from:   'ctl'
		to:     'sat'
		fields: [sf('blob', 'string')]
	}
	msg := refused(['Big'], s, [rw('Dyn', 'sat', 'model', ['Big'], [])], [], '')
	assert msg.contains('field "blob" is string')
	// RxStatus rides a lane only on a received signal
	s['St'] = SigInfo{
		name:   'St'
		from:   'ctl'
		to:     'sat'
		fields: [sf('status', 'RxStatus')]
	}
	assert refused(['St'], s, [rw('Dyn', 'sat', 'model', ['St'], [])], [], '').contains('RxStatus')
}

fn test_more_than_sixteen_lanes_is_refused() {
	mut s := down_sigs()
	mut fields := []SigField{}
	for i in 0 .. 9 {
		fields << sf('v${i}', 'u64') // 18 lanes
	}
	s['Huge'] = SigInfo{
		name:   'Huge'
		from:   'ctl'
		to:     'sat'
		fields: fields
	}
	assert refused(['Huge'], s, [rw('Dyn', 'sat', 'model', ['Huge'], [])], [], '').contains('18 lanes')
}

fn test_lane_pack_and_unpack_are_inverse_for_every_type() {
	si := down_sigs()['Wide']
	pack := lane_pack_lines(si, 'v', 'l', '')
	assert pack == [
		'l[0] = u32(xlane_f64_bits(v.t))',
		'l[1] = u32(xlane_f64_bits(v.t) >> 32)',
		'l[2] = u32(v.n)',
		'l[3] = if v.ok { u32(1) } else { u32(0) }',
		'l[4] = xlane_f32_bits(v.g)',
		'l[5] = u32(u64(v.c))',
		'l[6] = u32(u64(v.c) >> 32)',
	]
	unpack := lane_unpack_lines(si, 'st.xr', 2, 'inp.w', false, '')
	assert unpack == [
		'inp.w.t = xlane_f64_from((u64(st.xr[3]) << 32) | u64(st.xr[2]))',
		'inp.w.n = i16(st.xr[4])',
		'inp.w.ok = st.xr[5] != 0',
		'inp.w.g = xlane_f32_from(st.xr[6])',
		'inp.w.c = (u64(st.xr[8]) << 32) | u64(st.xr[7])',
	]
	assert lane_value('i64', 'a', 0) == 'i64((u64(a[1]) << 32) | u64(a[0]))'
	assert lane_value('RxStatus', 'a', 3) == 'xlane_rx_status(a[3])'
	// a lean received signal sets only its value field
	cmd := down_sigs()['Cmd']
	assert lane_unpack_lines(cmd, 'st.xr_cmd', 2, 'inp.cmd', true, '') == [
		'inp.cmd.cmd = st.xr_cmd[2]',
	]
}

fn test_bit_cast_helpers_are_emitted_only_when_used() {
	s := down_sigs()
	assert xlane_helpers([s['PtState']]) == []string{}
	h := xlane_helpers([s['Wide']]).join('\n')
	assert h.contains('fn xlane_f32_bits(x f32) u32')
	assert h.contains('fn xlane_f64_from(l u64) f64')
}

fn down_model() Model {
	fbs := [rw('Pt', 'ctl', 'fast', [], ['PtState']), rw('Dyn', 'sat', 'model', ['PtState', 'Cmd'], [])]
	d := xdown_derive(all_sigs, down_sigs(), two_core_parts(), fbs, [], '') or { panic(err) }
	return Model{
		sig_of:      down_sigs()
		sig_names:   all_sigs.clone()
		part:        two_core_parts()
		target:      TargetCfg{
			threadx: true
		}
		xdown_names: d.names
		xdown_off:   d.off
		xdown_lanes: d.lanes
		xdown_lean:  d.lean
		xdown_total: d.total
	}
}

fn test_layout_id_is_unchanged_without_down_channels_and_moves_with_them() {
	mut m := down_model()
	with := xcore_layout_id(m)
	m.xdown_names = []
	m.xdown_off = map[string]int{}
	without := xcore_layout_id(m)
	assert with != without
	// an empty map hashes as it always did: a model with no down channel keeps its id
	assert without == xcore_layout_id(Model{})
	// the direction is part of the hash: the same name in the up map is a different layout
	up := Model{
		sig_of:      down_sigs()
		xcore_names: ['PtState']
		xcore_idx:   {
			'PtState': 0
		}
	}
	assert xcore_layout_id(up) != with
}

fn test_contract_header_carries_offsets_lanes_and_the_budget_guard() {
	h := xdown_gen_h(down_model()).join('\n')
	assert h.contains('#define XCORE_OW_PT_STATE_OFF 0u')
	assert h.contains('#define XCORE_OW_PT_STATE_WORDS 2u')
	assert h.contains('#define XCORE_OW_CMD_OFF 96u')
	assert h.contains('#define XCORE_OW_CMD_WORDS 1u')
	assert h.contains('#define XCORE_OW_TOTAL 160u')
	assert h.contains('#if defined(XCORE_OW_MAX) && (XCORE_OW_TOTAL > XCORE_OW_MAX)')
	assert xdown_gen_h(Model{}) == []string{}
}

fn test_owner_boot_retracts_inits_every_channel_then_commits() {
	assert xdown_boot_lines(down_model()) == [
		'\tC.xcore_owner_begin() // owner->satellite window: retract, then init, then publish',
		'\tC.xcore_ow_init(u32(0), u32(2)) // PtState',
		'\tC.xcore_ow_init(u32(96), u32(1)) // Cmd',
		'\tC.xcore_owner_commit()',
	]
	assert xdown_boot_lines(Model{}) == []string{}
}

fn test_owner_writers_pack_and_publish_the_lean_one_publishes_the_decode() {
	m := down_model()
	g := xdown_pub_fns(m).join('\n')
	assert g.contains('fn xdown_pub_pt_state(v sig.PtState) {')
	assert g.contains('\tl[1] = v.inv')
	assert g.contains('\tC.xcore_opub_n(u32(0), &l[0])')
	assert !g.contains('xdown_pub_cmd') // lean: the comm thread publishes its decode directly
	assert xdown_lean_pub(m, 0x124) == 'C.xcore_opub_n(u32(96), &g_rx_last) // Cmd -> the satellite'
	assert xdown_lean_pub(m, 0x125) == ''
}

fn test_satellite_read_is_gated_and_keeps_the_port_default() {
	g := xdown_read_lines(down_model(), 'PtState')
	assert g[1] == '\tif C.xcore_down_read(u32(0), u32(2), &st.xr_pt_state[0]) != 0 {'
	assert g[2] == '\t\tinp.pt_state.seq = st.xr_pt_state[2]'
	assert g[3] == '\t\tinp.pt_state.inv = st.xr_pt_state[3]'
	assert g[4] == '\t}'
}

fn test_reader_state_lives_in_the_reading_thread() {
	mut m := down_model()
	assert xreader_state_fields(m, ['PtState', 'Cmd', 'Torque'], 'sat') == [
		'\txr_pt_state [4]u32 // PtState: owner nonce, seq, lanes (xcore_down_read)',
		'\txr_cmd [3]u32 // Cmd: owner nonce, seq, lanes (xcore_down_read)',
	]
	// the owner pass holds state for a WIDE up channel it reads, none for a down one
	m.xcore_xw_off = {
		'Wide': 0
	}
	assert xreader_state_fields(m, ['Wide', 'PtState'], '') == [
		'\txr_wide [8]u32 // Wide: seq, lanes (xcore_poll_n)',
	]
}

fn test_owner_wide_up_read_is_gated_on_the_layout_ack() {
	mut m := down_model()
	m.xcore_xw_off = {
		'Wide': 64
	}
	g := xup_wide_read_lines(m, 'Wide')
	assert g[0].starts_with('\tif C.xcore_layout_ok() != 0 {')
	assert g[1] == '\t\tC.xcore_poll_n(u32(64), 7, &st.xr_wide[0], &st.xr_wide[1])'
	assert g[2] == '\t\tif st.xr_wide[0] != 0 {'
	assert g[3] == '\t\t\tinp.wide.t = xlane_f64_from((u64(st.xr_wide[2]) << 32) | u64(st.xr_wide[1]))'
}

fn test_seams_are_linked_by_the_symbols_declared() {
	owner := glue_build_lines(xdown_owner_decls(down_model()), false)
	assert owner.contains(r'$(BOARD_XCORE_OWNER)')
	assert !owner.contains(r'$(BOARD_XCORE_SAT)')
	sat := glue_build_lines(['fn C.xcore_down_read(u32, u32, &u32) int'], false)
	assert sat.contains(r'$(BOARD_XCORE_SAT)')
	assert glue_build_lines([], false) == 'LOOM_GLUE_SRCS :=\n'
}
