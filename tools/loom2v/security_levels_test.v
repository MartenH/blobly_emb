module main

// REQ-DIAG-008: a server serves exactly the 0x27 levels its [[did]] gates name — bit L-1 for level
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
