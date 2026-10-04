module main

// @verifies REQ-DIAG-012

// codex #304 r4: when the operation-cycle signal and a watched signal ride one frame, the frame's
// result must land INSIDE the cycle either way — a rising edge starts the cycle before the
// group's results are consumed, a falling edge ends it after. Pinned here because no committed
// example puts both signals in one frame.
fn test_a_group_starts_the_cycle_before_its_results_and_ends_it_after() {
	mut m := Model{}
	m.fault_cycle = 'Ignition.on'
	m.faults = [FaultCfg{
		name:   'BrakeLost'
		signal: 'Brake'
		on:     'lost'
	}]
	m.sig_of['Brake'] = SigInfo{
		name:      'Brake'
		lost_type: 'u16'
	}
	owner := RxOwner{
		fmem:    'st.fmem'
		faults:  true
		publish: fn (si SigInfo, fld string) string {
			return ''
		}
	}
	// the cycle signal is listed FIRST in the frame: order in the frame must not matter
	out := rx_group_hooks(m, ['Ignition', 'Brake'], owner, '', '\t').join('\n')
	start := out.index('cycle_start()') or { -1 }
	result := out.index('st.fmem.consume(0') or { -1 }
	end := out.index('cycle_end()') or { -1 }
	assert start >= 0 && result >= 0 && end >= 0, out
	assert start < result, 'a rising edge must precede the group results:\n${out}'
	assert result < end, 'a falling edge must follow the group results:\n${out}'
	// a group without the cycle signal moves no cycle
	assert !rx_group_hooks(m, ['Brake'], owner, '', '\t').join('\n').contains('cycle_'), 'cycle moved by a group without its signal'
}
