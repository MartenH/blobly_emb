module main

// REQ-COM-008: the generated RxStatus puts never_received FIRST, so it is the zero value — a
// signal nothing has published yet (and a freestanding image, where no initialiser runs) reads
// not-yet-received, never healthy. The enum is emitted only when a signal uses it.
fn test_rx_status_zero_value_is_never_received() {
	mut sig_of := map[string]SigInfo{}
	sig_of['Speed'] = SigInfo{
		name:       'Speed'
		has_status: true
		fields:     [SigField{
			name: 'kph'
			typ:  'u16'
		}, SigField{
			name: 'status'
			typ:  'RxStatus'
		}]
	}
	out := emit_signals(sig_of, ['Speed'], 'ecu.toml').join('\n')
	body := out.all_after('pub enum RxStatus as u8 {').all_before('}')
	assert body.trim_space().starts_with('never_received'), body
	assert out.contains('\tstatus RxStatus')
	sig_of['Speed'] = SigInfo{
		name:   'Speed'
		fields: [SigField{
			name: 'kph'
			typ:  'u16'
		}]
	}
	assert !emit_signals(sig_of, ['Speed'], 'ecu.toml').join('\n').contains('RxStatus')
}
