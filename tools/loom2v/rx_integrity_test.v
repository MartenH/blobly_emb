module main

// REQ-COM-008: a frame that fails its protection check re-arms its COM deadline (so `integrity`
// becomes `timeout` once silence is the newer fact), and re-arms an E2E timeout only once that has
// already fired (a corrupt-only sender must still run it out from its last VALID frame). Pinned
// here because no committed example combines a COM deadline with a protected frame any more.
fn test_a_failed_frame_rearms_its_deadlines() {
	mut m := Model{}
	m.frames.rx_timeout_us['brake'] = 300_000
	m.frames.e2e_on['brake'] = true
	m.frames.frame_bus['brake'] = 'can0'
	m.frames.e2e_timeout_us['brake'] = 300_000
	out := rx_integrity(m, []string{}, 'brake', '', '', '\t').join('\n')
	assert out.contains('st.rx_brake_st.arm(now)'), out
	assert out.contains('if st.e2e_rx_brake.timedout {\n\t\tst.e2e_rx_brake.arm(now)'), out
	m.frames.rx_timeout_us['brake'] = 0
	m.frames.e2e_timeout_us['brake'] = 0
	assert rx_integrity(m, []string{}, 'brake', '', '', '\t').len == 0
}
