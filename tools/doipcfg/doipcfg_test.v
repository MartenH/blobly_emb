module doipcfg

import toml
import comm.udsauth

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

// @verifies REQ-NET-012 — what is exempt is listed (0x29, the other unlock service, among it);
// everything else needs a level, no table is refused, and either bench key needs allow_bench_key
fn test_every_service_but_the_open_ones_needs_a_level() {
	for sid in 0 .. 256 {
		assert needs_unlock(u8(sid)) == (u8(sid) !in [u8(0x10), 0x19, 0x22, 0x27, 0x29, 0x2E, 0x3E])
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
	assert bench_key_refusal('reference', false, false) != ''
	assert bench_key_refusal('reference', false, true) == ''
	assert bench_key_refusal('', false, true) != ''
	assert bench_key_refusal('', false, false) == ''
	// a 0x29 node's auth key naming the dev tester key: the same rule (REQ-NET-012)
	assert bench_key_refusal('', true, false).contains('auth_keys')
	assert bench_key_refusal('', true, true) == ''
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

// the programming handoff restarts the ECU into its bootloader: over the network it needs a level of
// its own ("0x10 02"), which 0x10's exemption does not give it
fn test_the_handoff_needs_a_level_over_the_network() {
	assert handoff_refusal(false, 0) == ''
	assert handoff_refusal(true, 0).contains('"0x10 02" = { security = N }')
	assert handoff_refusal(true, 1) == ''
	assert handoff_refusal(true, 9).contains('is not a 0x27 level')
}

// @verifies REQ-NET-012 — whether [uds] auth_keys names the dev tester key is ONE reading (loom2v's
// node gate and sysmodel's syscheck both ask it): any level's entry "reference", and nothing else —
// not a hex key, not a near spelling, not a table that is not one
fn test_auth_keys_name_the_bench_key_by_one_reading() {
	for text, want in {
		'auth_keys = { "1" = "reference" }':                                    true
		'auth_keys = { "1" = "${'ab'.repeat(32)}", "3" = "reference" }':       true
		'auth_keys = { "1" = "${'ab'.repeat(32)}" }':                           false
		'auth_keys = { "1" = "Reference" }':                                    false
		'auth_keys = "reference"':                                              false
		'auth_keys = {}':                                                       false
	} {
		doc := toml.parse_text(text) or { panic(err) }
		assert auth_reference(doc.to_any().as_map()['auth_keys'] or { panic('no auth_keys') }) == want, text
	}
	assert names_bench_key(toml.Any('reference')) && !names_bench_key(toml.Any(1))
}

// the dev tester key's own hex digits, either case
const reference_hex = '29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7'

// @verifies REQ-NET-012 REQ-DIAG-126 — the dev tester key written out as its 64 hex digits, in
// either case, IS the bench key (the key is compared, not its spelling): a network-reachable node
// naming it so is refused without allow_bench_key, as "reference" is
fn test_the_bench_key_written_as_hex_is_the_bench_key() {
	for spelling in [reference_hex, reference_hex.to_upper(), ' ${reference_hex} '] {
		assert names_bench_key(toml.Any(spelling)), spelling
		doc := toml.parse_text('auth_keys = { "2" = "${spelling}" }') or { panic(err) }
		ak := doc.to_any().as_map()['auth_keys'] or { panic('no auth_keys') }
		assert auth_reference(ak), spelling
		assert bench_key_refusal('', auth_reference(ak), false).contains('PUBLIC dev tester key')
	}
	// one digit off is another key
	assert !names_bench_key(toml.Any(reference_hex[..63] + '6'))
	assert key_bytes(reference_hex) or { panic('not decoded') } == udsauth.reference_key
	assert key_bytes('zz' + reference_hex[2..]) == none && key_bytes(reference_hex[2..]) == none
}

// small_order_hex: every encoding of a small-order point (bcrypto's test has their derivation)
const small_order_hex = [
	'0100000000000000000000000000000000000000000000000000000000000000',
	'ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
	'0000000000000000000000000000000000000000000000000000000000000000',
	'0000000000000000000000000000000000000000000000000000000000000080',
	'26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05',
	'26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85',
	'c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a',
	'c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa',
	'0100000000000000000000000000000000000000000000000000000000000080',
	'ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
	'edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
	'edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
	'eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
	'eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
]

// @verifies REQ-DIAG-126 — a configured public key of small order is refused, in every encoding
// (canonical or not), by the one rule every configured key goes through; real keys pass, and a
// non-point is refused as such
fn test_a_small_order_key_is_refused() {
	for h in small_order_hex {
		k := key_bytes(h) or { panic('not decoded: ${h}') }
		assert key_refusal(k).contains('small order'), h
	}
	assert key_refusal(udsauth.reference_key) == ''
	image := key_bytes('03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8') or {
		panic('image key')
	}
	assert key_refusal(image) == ''
	not_point := key_bytes('02' + '00'.repeat(31)) or { panic('decode') }
	assert key_refusal(not_point).contains('not a curve point')
}
