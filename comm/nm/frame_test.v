module nm

// @verifies REQ-NM-005, REQ-NM-009, REQ-NM-010, REQ-NM-011, REQ-NM-012, REQ-NM-013
// NM frame encode/decode + control-bit reactions. Deterministic; drive `now` by hand.

const tcfg = Timings{
	msg_cycle_us:  100
	timeout_us:    300
	repeat_us:     200
	wait_sleep_us: 150
}

// REQ-NM-011: each NM frame carries the source node id.
fn test_frame_roundtrip_carries_nid() {
	f := Frame{
		nid: 0x12
		cbv: cbv_ready_to_sleep | cbv_pn_info
		pn:  0x05
	}
	b := f.to_bytes()
	assert b[0] == 0x12 // NID byte 0
	assert b[1] == cbv_ready_to_sleep | cbv_pn_info
	assert b[2] == 0x05 // PN low byte
	g := parse_frame(b)
	assert g.nid == 0x12
	assert g.cbv == f.cbv
	assert g.pn == 0x05
}

// REQ-NM-013: active wakeup is indicated; a passive (rx) wakeup is not.
fn test_active_wakeup_indication() {
	mut a := Nm{
		cfg: tcfg
	}
	a.request(0) // we actively wake
	assert a.build_frame(7, 0).cbv & cbv_active_wakeup != 0

	mut p := Nm{
		cfg: tcfg
	}
	p.on_rx(0) // woken passively by another node
	assert p.build_frame(8, 0).cbv & cbv_active_wakeup == 0
}

// REQ-NM-012: ready-to-sleep is indicated only after the local release.
fn test_ready_to_sleep_indication() {
	mut n := Nm{
		cfg: tcfg
	}
	n.request(0)
	assert n.build_frame(7, 0).cbv & cbv_ready_to_sleep == 0 // still needed
	n.release()
	assert n.build_frame(7, 0).cbv & cbv_ready_to_sleep != 0 // released
}

// REQ-NM-009: receiving a repeat-message request re-syncs us to repeat_message.
fn test_rmr_resync() {
	mut n := Nm{
		cfg: tcfg
	}
	n.request(0)
	_ := n.tick(0)
	n.requested = true
	n.enter(.normal_operation, 0)
	assert n.state == .normal_operation
	rmr := Frame{
		nid: 9
		cbv: cbv_repeat_msg_request
	}
	n.on_frame(10, rmr)
	assert n.state == .repeat_message // re-synchronised
}

// REQ-NM-010: a partial network is demanded while any node requests it, and stops
// being demanded once the requesting node clears it OR goes silent.
fn test_partial_network_demand() {
	mut n := Nm{
		cfg: tcfg
	}
	// local request for PN 2
	assert n.pn_demanded(0, 2, u64(1) << 2)
	assert !n.pn_demanded(0, 5, u64(1) << 2)
	// a remote node (9) requests PN 5
	n.on_frame(0, Frame{
		nid: 9
		cbv: cbv_pn_info
		pn:  u64(1) << 5
	})
	assert n.pn_demanded(0, 5, 0)
	// node 9 later sends a frame with PN 5 cleared -> no longer demanded (replace, not OR)
	n.on_frame(10, Frame{
		nid: 9
		cbv: cbv_pn_info
		pn:  0
	})
	assert !n.pn_demanded(10, 5, 0)
	// it requests PN 5 again, then goes silent past the timeout -> demand expires
	n.on_frame(20, Frame{
		nid: 9
		cbv: cbv_pn_info
		pn:  u64(1) << 5
	})
	assert n.pn_demanded(20, 5, 0)
	assert !n.pn_demanded(20 + tcfg.timeout_us + 1, 5, 0) // silent too long
	// and once asleep everything clears
	n.enter(.bus_sleep, 0)
	assert !n.pn_demanded(0, 5, 0)
}

// REQ-NM-005: NM reports its current network state.
fn test_reports_state() {
	mut n := Nm{
		cfg: tcfg
	}
	assert n.report() == .bus_sleep
	n.request(0)
	assert n.report() == .repeat_message
	assert n.awake()
}
