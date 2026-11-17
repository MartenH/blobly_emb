module main

// REQ-DIAG-026: a server serves exactly the 0x27 levels its [[did]] gates name — bit L-1 for level
// L, read and write gates alike — and nothing when no gate names one.
fn test_security_levels_come_from_the_did_gates() {
	assert security_levels([]DidCfg{}) == 0
	assert security_levels([DidCfg{
		id: 1
	}]) == 0
	assert security_levels([DidCfg{
		id:            1
		read_security: 1
	}, DidCfg{
		id:             2
		write_security: 3
	}, DidCfg{
		id:             3
		read_security:  8
		write_security: 1
	}]) == 0b1000_0101
}

// a level a control names is served too (REQ-DIAG-066's sources): bit L-1, as a gate's
fn test_a_control_names_a_level_the_server_serves() {
	assert security_levels([DidCfg{
		id:               1
		signal:           'X'
		control_params:   0x0F
		control_sessions: 0x04
		control_security: 2
	}]) == 0b10
	mut m := Model{}
	m.dids = [DidCfg{
		id:               1
		signal:           'X'
		control_params:   0x09
		control_sessions: 0x04
		control_security: 3
	}]
	assert sa_levels(m) == 0b100
}
