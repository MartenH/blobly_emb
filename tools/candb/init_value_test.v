module candb

// @verifies REQ-COM-011

// GenSigStartValue is read per signal, as written, and only from its own BA_ record: a file-wide
// default is not a declaration, and a record naming another frame or signal attaches nowhere.
fn test_gen_sig_start_value_is_parsed_onto_its_signal() {
	dbc := 'BO_ 256 Frame: 8 Gw
 SG_ A : 0|8@1+ (1,0) [10|20] "" Sink
 SG_ B : 8|8@1- (1,0) [-5|5] "" Sink
 SG_ C : 16|8@1+ (1,0) [0|255] "" Sink

BO_ 2147483904 ExtFrame: 8 Gw
 SG_ A : 0|8@1+ (1,0) [0|255] "" Sink

BA_DEF_ SG_ "GenSigStartValue" INT 0 255;
BA_DEF_DEF_ "GenSigStartValue" 0;
BA_ "GenSigStartValue" SG_ 256 A 12;
BA_ "GenSigStartValue" SG_ 256 B -3;
BA_ "GenSigStartValue" SG_ 2147483904 A 7;
BA_ "GenSigStartValue" SG_ 256 Nope 1;
'
	db := parse_dbc(dbc) or { panic(err) }
	f := db.lookup_frame(0x100, false) or { panic('no Frame') }
	assert f.signals[0].start_value == '12'
	assert f.signals[1].start_value == '-3'
	assert f.signals[2].start_value == '', 'a BA_DEF_DEF_ default is not a declaration'
	e := db.lookup_frame(0x100, true) or { panic('no ExtFrame') }
	assert e.signals[0].start_value == '7'
}

fn isig(name string, start int, len int, signed bool, factor f64, offset f64, min f64, max f64, sv string) Signal {
	return Signal{
		name:        name
		start_bit:   start
		length:      len
		is_signed:   signed
		factor:      factor
		offset:      offset
		minimum:     min
		maximum:     max
		start_value: sv
	}
}

// With no start value declared, a signal starts at the physical value nearest 0 inside its range.
fn test_init_raw_without_a_start_value_is_the_in_range_value_nearest_zero() {
	assert isig('S', 0, 8, false, 1, 0, 0, 100, '').init_raw()! == 0 // 0 in range
	assert isig('S', 0, 8, false, 1, 0, 10, 20, '').init_raw()! == 10 // range above 0: its minimum
	assert isig('S', 0, 8, true, 1, 0, -20, -10, '').init_raw()! == u64(-10) & 0xFF // below 0: its maximum
	assert isig('S', 0, 8, false, 1, -40, -40, 215, '').init_raw()! == 40 // offset: physical 0 is raw 40
	assert isig('S', 0, 8, false, 0.5, 0.25, 0, 100, '').init_raw()! == 0 // -0.5 steps: nearest grid point, held to 0
	assert isig('S', 0, 8, false, -1, 0, -20, -10, '').init_raw()! == 10 // negative factor: -10 is raw 10
	assert isig('S', 0, 8, false, 0.1, 0, 2.5, 3.0, '').init_raw()! == 25 // ceil of the minimum on the grid
	assert isig('S', 0, 8, false, 1, 0, 0, 0, '').init_raw()! == 0 // no range declared: the width
}

// A declared start value is a RAW value: kept when it lies inside the raw range or names a VAL_ entry
// the send rule lets through, refused otherwise.
fn test_init_raw_takes_a_start_value_inside_the_range_and_refuses_one_outside() {
	assert isig('S', 0, 8, false, 1, 0, 10, 20, '15').init_raw()! == 15
	assert isig('S', 0, 8, false, 1, 0, 10, 20, '15.0').init_raw()! == 15
	assert isig('S', 0, 8, false, 0.5, -40, -40, 87.5, '100').init_raw()! == 100 // raw, not physical
	assert isig('S', 0, 8, true, 1, 0, -50, 50, '-3').init_raw()! == 0xFD
	assert isig('S', 0, 64, false, 1, 0, 0, 0, '18446744073709551615').init_raw()! == ~u64(0)
	for bad in ['5', '21', '-1', '256', '12.5', 'x', '1e1'] {
		if r := isig('S', 0, 8, false, 1, 0, 10, 20, bad).init_raw() {
			assert false, 'start value ${bad} on [10|20] gave ${r}, want a refusal'
		} else {
			assert err.msg().contains('signal "S"'), err.msg()
		}
	}
	// signed: 255 is not -1 of an 8-bit signed signal, it is outside the width
	if r := isig('S', 0, 8, true, 1, 0, -50, 50, '255').init_raw() {
		assert false, 'got ${r}'
	}
	// a VAL_ entry outside the range ("SNA") is what the send rule sends as named
	mut sna := isig('S', 0, 8, false, 1, 0, 0, 250, '255')
	sna = Signal{
		...sna
		values: {
			u64(255): 'SNA'
		}
	}
	assert sna.init_raw()! == 255
}

// The PDU's initial payload: every signal at its initial value, so an unpublished field whose range
// excludes 0 is in range; a refused start value refuses the message.
fn test_init_payload_puts_every_signal_at_its_initial_value() {
	m := Message{
		name:    'M'
		dlc:     4
		signals: [isig('Pub', 0, 8, false, 1, 0, 0, 255, ''), isig('Temp', 8, 8, false, 1, -40, -40,
			215, ''), isig('Gear', 16, 4, false, 1, 0, 1, 6, ''),
			isig('Mode', 20, 4, false, 1, 0, 0, 15, '9')]
	}
	assert m.init_payload()! == [u8(0), 40, 0x91, 0]
	bad := Message{
		name:    'B'
		dlc:     1
		signals: [isig('X', 0, 8, false, 1, 0, 1, 6, '7')]
	}
	if p := bad.init_payload() {
		assert false, 'got ${p}'
	} else {
		assert err.msg().contains('message "B"') && err.msg().contains('signal "X"'), err.msg()
	}
}

// A multiplexed message starts with the signals its multiplexor's initial value selects.
fn test_init_payload_of_a_multiplexed_message_follows_the_switch() {
	mut sw := isig('Sw', 0, 8, false, 1, 0, 2, 3, '')
	sw = Signal{
		...sw
		is_multiplexor: true
	}
	mut a := isig('A', 8, 8, false, 1, 0, 5, 9, '')
	a = Signal{
		...a
		is_multiplexed:    true
		multiplexor_value: 2
	}
	mut b := isig('B', 8, 8, false, 1, 0, 7, 9, '')
	b = Signal{
		...b
		is_multiplexed:    true
		multiplexor_value: 3
	}
	m := Message{
		name:    'Mx'
		dlc:     2
		signals: [sw, a, b]
	}
	assert m.init_payload()! == [u8(2), 5]
}
