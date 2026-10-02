module doipcfg

import toml

// allow_bench_key: a boolean, written back under its own name, and refused as anything else
fn test_allow_bench_key_is_read_written_and_checked() {
	doc := toml.parse_text('allow_bench_key = true') or { panic(err) }
	p, not_int := parse(doc.to_any().as_map())
	assert not_int.len == 0 && p.allow_bench_key && p.problems().len == 0
	assert p.lines() == ['allow_bench_key = true']
	bad := toml.parse_text('allow_bench_key = 1') or { panic(err) }
	q, _ := parse(bad.to_any().as_map())
	assert !q.allow_bench_key && q.problems().any(it.contains('must be true or false'))
	assert bench_key in keys()
}

// REQ-NET-012: what is exempt is listed; everything else needs a level, and no table is refused
fn test_every_service_but_the_open_ones_needs_a_level() {
	for sid in 0 .. 256 {
		assert needs_unlock(u8(sid)) == (u8(sid) !in [u8(0x10), 0x19, 0x22, 0x27, 0x2E, 0x3E])
	}
	assert service_refusals(false, []).len == 1
	assert service_refusals(true, [ServiceRow{
		sid: 0x22
	}, ServiceRow{
		sid:      0x11
		security: 1
	}]).len == 0
	assert service_refusals(true, [ServiceRow{
		sid: 0x14
	}, ServiceRow{
		sid: 0x85
	}]).len == 2
	assert bench_key_refusal('reference', false) != ''
	assert bench_key_refusal('reference', true) == ''
	assert bench_key_refusal('', true) != ''
	assert bench_key_refusal('', false) == ''
}
