module main

// The ThreadX multi-bus GATEWAY comm owner: sysnode (examples/system_full) opens one channel
// per FDCAN bus and forwards LAYOUT-IDENTICAL routes as a raw payload copy + id remap (no
// on-target decode/re-encode). These guard the pure emit helpers that build that comm thread —
// the target cross-build is not gated in CI, so the codegen is checked here.

fn test_fdcan_index_and_channel_var() {
	// the driver opens a bus by its single index digit (blob_can_open: name[0]-'0')
	assert fdcan_index_of('can0') == '0'
	assert fdcan_index_of('can2') == '2'
	assert fdcan_index_of('body') == '0' // no digit -> 0 (the telem-bus rule rejects this earlier)
	// the telem bus reuses `ch`; every other route bus gets its own `ch_<bus>`
	assert gw_var('can0', 'can0') == 'ch'
	assert gw_var('can1', 'can0') == 'ch_can1'
	assert gw_var('can2', 'can0') == 'ch_can2'
}

fn test_gateway_extra_buses_excludes_telem_bus() {
	m := Model{
		telem:  TelemetryCfg{
			bus: 'can0'
		}
		routes: [
			Route{
				from_bus: 'can0'
				to_bus:   'can1'
				signal:   'A'
			},
			Route{
				from_bus: 'can2'
				to_bus:   'can0'
				signal:   'B'
			},
		]
	}
	// can0 is the telem bus (already `ch`); the extras are can1 then can2, first-seen order
	assert gateway_extra_buses(m) == ['can1', 'can2']
}

fn test_gateway_forward_arms_raw_copy_and_id_remap() {
	m := Model{
		telem:  TelemetryCfg{
			bus: 'can0'
		}
		routes: [
			Route{
				from_bus:   'can0'
				from_id:    0x120
				from_dlc:   8
				to_bus:     'can1'
				to_id:      0x130
				signal:     'VehicleSpeed'
				raw_ident:  true
			},
			Route{
				from_bus:   'can1'
				from_id:    0x132
				from_dlc:   8
				to_bus:     'can0'
				to_id:      0x125
				signal:     'SteeringAngle'
				raw_ident:  true
			},
		]
	}
	// a can0-sourced route: match the source id/dlc, re-send under the dest id on ch_can1
	a := gateway_forward_arms(m, 'can0').join('\n')
	assert a.contains('rx.id == u32(0x120) && rx.len == 8')
	assert a.contains('id:  u32(0x130)')
	assert a.contains('ff.data = rx.data') // raw copy — no decode/re-encode
	assert a.contains('ch_can1.tx_ready()')
	assert a.contains('ch_can1.send(ff)')
	assert a.contains('g_fwd_count++') // counted inside the tx_ready gate (only frames actually sent)
	// a can1-sourced route forwards back onto the telem bus, whose channel is `ch`
	b := gateway_forward_arms(m, 'can1').join('\n')
	assert b.contains('rx.id == u32(0x132)')
	assert b.contains('ch.tx_ready()')
	assert b.contains('ch.send(ff)')
	// each source bus only emits ITS routes (no cross-contamination)
	assert !a.contains('0x132')
	assert !b.contains('0x120')
	// NM OFF: no NM gate on the forward — only tx_ready
	assert !a.contains('g_nm.awake()')
}

fn test_gateway_forward_arms_nm_gated_only_on_the_managed_bus() {
	// The single [nm] instance manages ONE bus (nm.bus). A forward whose DESTINATION is that
	// bus must stay silent while asleep (REQ-COM-007); a forward to a bus NM does not manage is
	// untouched. Here NM manages can1: the can0->can1 route is gated, the can0->can2 route is not.
	m := Model{
		telem:  TelemetryCfg{
			bus: 'can0'
		}
		nm:     NmCfg{
			on:  true
			bus: 'can1' // NM manages the edge bus
		}
		routes: [
			Route{
				from_bus:  'can0'
				from_id:   0x120
				from_dlc:  8
				to_bus:    'can1' // -> managed bus: GATED
				to_id:     0x130
				signal:    'VehicleSpeed'
				raw_ident: true
			},
			Route{
				from_bus:  'can0'
				from_id:   0x121
				from_dlc:  8
				to_bus:    'can2' // -> unmanaged bus: NOT gated
				to_id:     0x140
				signal:    'Other'
				raw_ident: true
			},
		]
	}
	a := gateway_forward_arms(m, 'can0').join('\n')
	// the managed-bus forward gates on NM (gate precedes tx_ready)...
	assert a.contains('if g_nm.awake() && ch_can1.tx_ready() {')
	// ...the unmanaged-bus forward does NOT gate on NM
	assert a.contains('if ch_can2.tx_ready() {')
	assert !a.contains('g_nm.awake() && ch_can2.tx_ready()')
}
