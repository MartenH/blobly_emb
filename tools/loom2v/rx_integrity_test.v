module main

// REQ-COM-008, REQ-E2E-004: a frame SecOC refuses is a protection failure like an E2E CRC error —
// com.RxMonitor.rejected restarts its deadlines from it (comm/com tests that rule) — and it never
// reaches E2E: only an AUTHENTIC frame is checked, with SecOC's bytes left out of the CRC. Pinned
// here because no committed example composes the two on a received frame.
fn test_only_an_authentic_frame_reaches_the_e2e_check() {
	mut m := Model{}
	m.frames.rx_timeout_us['brake'] = 300_000
	m.frames.e2e_on['brake'] = true
	m.frames.secoc_on['brake'] = true
	m.frames.frame_bus['brake'] = 'can0'
	m.frames.e2e_timeout_us['brake'] = 300_000
	m.frames.e2e_id['brake'] = 0x44
	m.frames.e2e_crc['brake'] = 4
	m.frames.e2e_ctr['brake'] = 5
	m.frames.secoc_fresh['brake'] = 1
	m.frames.secoc_mac['brake'] = 2
	m.frames.secoc_maclen['brake'] = 2
	owner := RxOwner{
		fmem: 'st.fmem'
		rx_on: 'st.conn_diag.server.rx_enabled()'
		publish: fn (si SigInfo, fld string) string {
			return ''
		}
	}
	out := rx_frame_arm(m, 'brake', []string{}, false, 'can0', owner, '\t').join('\n')
	verify := out.index('st.secoc_rx_brake.verify(') or { -1 }
	check := out.index('st.rxm_brake.e2e.check_ex(&rx.data[0], int(brake_dlc), u16(0x44), 4, 5, 1, 1, 2, 2)') or {
		-1
	}
	refused := out.index('p_brake = st.rxm_brake.rejected(now, st.rxg.on)') or { -1 }
	assert verify >= 0 && check > verify && refused > check, out
	assert out.contains('p_brake = st.rxm_brake.checked(now, chk_brake, st.rxg.on, st.rxg.receiving(), st.rxg.suspended())'), out
}

// A signal with no status has nothing to carry a protection failure: an integrity verdict publishes
// nothing to it (its last value stands), and moves no operation cycle it drives.
fn test_an_integrity_failure_skips_a_signal_without_a_status() {
	mut m := Model{}
	m.frames.e2e_on['ign'] = true
	m.frames.frame_bus['ign'] = 'can0'
	m.frames.e2e_timeout_us['ign'] = 300_000
	m.sig_of['Ign'] = SigInfo{
		name: 'Ign'
		bus: 'can0'
		val_field: 'on'
		val_type: 'bool'
		dbc_msg: 'ign'
	}
	owner := RxOwner{
		fmem: 'st.fmem'
		publish: fn (si SigInfo, fld string) string {
			return 'PUBLISH(${fld})'
		}
	}
	out := rx_frame_arm(m, 'ign', ['Ign'], false, 'can0', owner, '\t').join('\n')
	assert out.contains('if p_ign != .integrity {\n\t\t\t\tPUBLISH(ign)'), out
}
