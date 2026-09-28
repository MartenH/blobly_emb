module ecumodel

fn test_snake_name_makes_an_acronym_its_own_word() {
	cases := {
		'EngineOverRev': 'engine_over_rev'
		'ABSActive':     'abs_active'
		'VINCheck':      'vin_check'
		'LED5State':     'led5_state'
		'HTTPServer':    'http_server'
		'BrakeABS':      'brake_abs'
		'E2EStatus':     'e2_e_status'
		'A':             'a'
		'AB':            'ab'
		'can0':          'can0'
		'BrakeMsgLost':  'brake_msg_lost'
	}
	for name, want in cases {
		assert snake_name(name) == want, '${name} -> ${snake_name(name)}, want ${want}'
	}
}

fn test_pascal_ok_is_the_one_spelling() {
	for ok in ['EngineOverRev', 'ABSActive', 'Led5', 'A'] {
		assert pascal_ok(ok), ok
	}
	for bad in ['', 'engineOverRev', 'Engine_Over_Rev', 'engine_over_rev', '_Engine', 'Engine Rev',
		'5Engine'] {
		assert !pascal_ok(bad), bad
	}
}

fn test_snake_scope_refuses_a_repeat_and_a_collision() {
	mut s := snake_scope('signal')
	assert s.add('ABSActive') == none
	assert s.add('BrakeOn') == none
	assert (s.add('AbsActive') or { '' }) == 'signal "AbsActive" collides with "ABSActive": both generate `abs_active`'
	assert (s.add('BrakeOn') or { '' }) == 'duplicate signal "BrakeOn"'
}
