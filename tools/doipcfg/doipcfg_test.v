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

// a level outside 0x27's 1..8 gates nothing — it is refused, never read as authentication
fn test_an_out_of_range_level_is_refused() {
	for lvl in [i64(9), 256, -1] {
		errs := service_refusals(true, [ServiceRow{
			sid:      0x11
			security: lvl
		}])
		assert errs.len == 1 && errs[0].contains('is not a 0x27 level'), '${lvl}: ${errs}'
	}
	assert service_refusals(true, [ServiceRow{
		sid:      0x11
		security: 8
	}]).len == 0
}

// a writable DID needs its own write gate or the 0x2E row's
fn test_a_writable_did_needs_a_gate() {
	ungated := [DidWrite{
		id:       0x0102
		writable: true
	}]
	assert did_refusals([], ungated).len == 1
	assert did_refusals([ServiceRow{
		sid:      0x2E
		security: 1
	}], ungated).len == 0
	assert did_refusals([], [DidWrite{
		id:       0x0102
		writable: true
		security: 1
	}]).len == 0
	assert did_refusals([], [DidWrite{
		id: 0xF189
	}]).len == 0
}

// a DID write level, and a 0x2E row level, out of range gate nothing
fn test_out_of_range_write_levels_gate_nothing() {
	for lvl in [i64(9), -1] {
		errs := did_refusals([], [DidWrite{
			id:       0x0102
			writable: true
			security: lvl
		}])
		assert errs.len == 1 && errs[0].contains('is not a 0x27 level'), '${lvl}: ${errs}'
		// an out-of-range 0x2E row does not cover an ungated DID either
		assert did_refusals([ServiceRow{
			sid:      0x2E
			security: lvl
		}], [DidWrite{
			id:       0x0102
			writable: true
		}]).len == 1
	}
}
