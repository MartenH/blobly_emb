module ecumodel

// The one reader of how a diagnostic connection states its ids (addressing.v): an [isotp], a
// system.toml diag and a [[doip.route]] — normal addressing on 11- or 29-bit ids, normal fixed
// addressing's derived ids, and every refusal, with the ids read kept when refused.
// @verifies REQ-CAN-TP-040 REQ-CAN-TP-041 REQ-TOPO-013 REQ-NET-021
import toml
import tools.cfgschema

fn isotp_of(src string) (DiagIds, []string) {
	doc := toml.parse_text('[isotp]\nbus = "can0"\n' + src) or { panic(err) }
	m := doc.to_any().as_map()['isotp'] or { panic('no [isotp]') }
	return diag_ids(cfgschema.ecu, isotp_keys, m.as_map(), '[isotp]')
}

// isotp_unwalked_of: the same [isotp] where no schema walk ran first (loom2v)
fn isotp_unwalked_of(src string) (DiagIds, []string) {
	doc := toml.parse_text('[isotp]\nbus = "can0"\n' + src) or { panic(err) }
	m := doc.to_any().as_map()['isotp'] or { panic('no [isotp]') }
	return diag_ids(cfgschema.ecu, isotp_keys_unwalked, m.as_map(), '[isotp]')
}

fn diag_of(src string) (DiagIds, []string) {
	doc := toml.parse_text(src) or { panic(err) }
	return diag_ids(cfgschema.system, diag_keys, doc.to_any().as_map(), 'node "n" diag')
}

fn has(errs []string, want string) bool {
	return errs.any(it.contains(want))
}

fn test_normal_addressing_on_11_and_29_bit_ids() {
	a, ea := isotp_of('rx_id = 0x7E0\ntx_id = 0x7E8\nfunctional_id = 0x7DF\n')
	assert ea == []
	assert a.rx == 0x7E0 && a.tx == 0x7E8 && a.functional == 0x7DF && !a.ext && !a.fixed
	b, eb := isotp_of('rx_id = 0x18DA10F1\ntx_id = 0x18DAF110\nfunctional_id = 0x18DB33F1\next = true\n')
	assert eb == []
	assert b.rx == 0x18DA10F1 && b.tx == 0x18DAF110 && b.functional == 0x18DB33F1 && b.ext
	// 29-bit on small ids is a 29-bit id still
	c, ec := isotp_of('rx_id = 0x7B0\ntx_id = 0x7B8\next = true\n')
	assert ec == [] && c.ext && c.rx == 0x7B0
	// ext = false is the default spelled out
	_, ed := isotp_of('rx_id = 0x7B0\ntx_id = 0x7B8\next = false\n')
	assert ed == []
}

fn test_a_wide_id_without_ext_is_refused_and_still_read() {
	a, ea := isotp_of('rx_id = 0x800\ntx_id = 0x7E8\n')
	assert ea == ['[isotp] rx_id 0x800 must be a standard 11-bit id (<= 0x7FF) — ext = true makes it 29-bit']
	assert a.rx == 0x800 // the id read, kept for a reader that runs no gate
	_, eb := isotp_of('rx_id = 0x7E0\ntx_id = 0x7E8\nfunctional_id = 0x18DB33F1\n')
	assert has(eb, 'functional_id 0x18db33f1 must be a standard 11-bit id')
	_, ec := isotp_of('rx_id = 0x20000000\ntx_id = 0x7E8\next = true\n')
	assert ec == ['[isotp] rx_id = 0x20000000 is out of range (0x0..0x1fffffff)']
	_, ed := isotp_of('rx_id = -1\ntx_id = 0x7E8\next = true\n')
	assert has(ed, 'rx_id = 0x') && has(ed, 'is out of range')
	// a wrong type is the walk's to say where one ran, the reader's where none did
	_, ee := isotp_of('rx_id = "0x7E0"\ntx_id = 0x7E8\n')
	assert ee == []
	_, eu := isotp_unwalked_of('rx_id = "0x7E0"\ntx_id = 0x7E8\n')
	assert eu == ['[isotp] rx_id must be an integer']
	_, ef := isotp_of('rx_id = 0x7E0\n')
	assert has(ef, '[isotp] needs tx_id')
	_, eg := isotp_of('rx_id = 0x7E0\ntx_id = 0x7E8\nfunctional_id = 0x7E0\n')
	assert has(eg, 'functional_id 0x7e0 is also the connection\'s physical rx_id / tx_id')
}

fn test_normal_fixed_addressing_derives_its_ids() {
	a, ea := isotp_of('addressing = "normal_fixed"\nsa = 0x10\nta = 0xF1\nfunctional_ta = 0x33\n')
	assert ea == []
	assert a.rx == 0x18DA10F1 && a.tx == 0x18DAF110 && a.functional == 0x18DB33F1
	assert a.ext && a.fixed
	b, eb := isotp_of('addressing = "normal_fixed"\nsa = 0x10\nta = 0xF1\n')
	assert eb == [] && b.functional == 0 // no functional_ta: no functional id
}

fn test_normal_fixed_addressing_states_its_ids_one_way() {
	fixed := 'addressing = "normal_fixed"\nsa = 0x10\nta = 0xF1\n'
	for extra, key in {
		'rx_id = 0x7E0\n':         'rx_id'
		'tx_id = 0x7E8\n':         'tx_id'
		'functional_id = 0x7DF\n': 'functional_id'
		'ext = true\n':            'ext'
	} {
		_, e := isotp_of(fixed + extra)
		assert e == ['[isotp] ${key} is given with addressing = "normal_fixed", whose ids derive from sa and ta — one way to state an id'], e.str()
	}
}

fn test_normal_fixed_addresses_are_refused_when_missing_or_out_of_range() {
	a, ea := isotp_of('addressing = "normal_fixed"\nta = 0xF1\n')
	assert ea == ['[isotp] addressing = "normal_fixed" needs sa (the node\'s own address)']
	assert a.rx == 0 && a.tx == 0 && a.ext // nothing derived from half an address pair
	_, eb := isotp_of('addressing = "normal_fixed"\nsa = 0x10\n')
	assert has(eb, 'needs ta (the tester\'s address)')
	_, ec := isotp_of('addressing = "normal_fixed"\nsa = 256\nta = 0xF1\n')
	assert ec == ['[isotp] sa = 0x100 is out of range (0x0..0xff)']
	_, ed := isotp_of('addressing = "normal_fixed"\nsa = -1\nta = 0xF1\n')
	assert has(ed, 'sa = 0x') && has(ed, 'is out of range (0x0..0xff)')
	_, ee := isotp_of('addressing = "normal_fixed"\nsa = 0xF1\nta = 0xF1\n')
	assert ee == ['[isotp] sa and ta are both 0xf1 — a request and its answer would be one id']
	_, ef := isotp_of('addressing = "normal_fixed"\nsa = 0x10\nta = 0xF1\nfunctional_ta = 0x133\n')
	assert has(ef, 'functional_ta = 0x133 is out of range')
	ga, eg := isotp_of('addressing = "normal_fixed"\nsa = "0x10"\nta = 0xF1\n')
	assert eg == [] && ga.rx == 0 // the walk said it; nothing derived from an unreadable address
	_, eu := isotp_unwalked_of('addressing = "normal_fixed"\nsa = "0x10"\nta = 0xF1\n')
	assert eu == ['[isotp] sa must be an integer']
}

fn test_the_other_formats_keys_and_unknown_addressing_are_refused() {
	_, ea := isotp_of('rx_id = 0x7E0\ntx_id = 0x7E8\nfunctional_ta = 0x33\n')
	assert ea == ['[isotp] functional_ta is for addressing = "normal_fixed" — normal addressing states rx_id and tx_id']
	_, eb := isotp_of('rx_id = 0x7E0\ntx_id = 0x7E8\nsa = 0x10\n')
	assert has(eb, 'sa is for addressing = "normal_fixed"')
	c, ec := isotp_of('addressing = "extended"\nrx_id = 0x7E0\ntx_id = 0x7E8\n')
	assert ec == ['[isotp] addressing "extended" is not one of "normal", "normal_fixed" — extended and mixed addressing are not supported']
	assert c.rx == 0x7E0 && c.tx == 0x7E8 // the ids given, kept for a reader that runs no gate
	// an addressing that cannot be read judges nothing further: the rest would be judged by the
	// wrong format's rules (a misspelt normal_fixed is one refusal, not one per key)
	_, ef := isotp_of('addressing = "normal_fxed"\nsa = 0x10\nta = 0xF1\n')
	assert ef == ['[isotp] addressing "normal_fxed" is not one of "normal", "normal_fixed" — extended and mixed addressing are not supported']
	_, eg := isotp_of('addressing = 5\nsa = 0x10\nta = 0xF1\n')
	assert eg == [] // the walk says the type
	_, eh := isotp_unwalked_of('addressing = 5\nsa = 0x10\nta = 0xF1\n')
	assert eh == ['[isotp] addressing 5 is not one of "normal", "normal_fixed" — extended and mixed addressing are not supported']
	_, ed := isotp_of('rx_id = 0x7E0\ntx_id = 0x7E8\next = "yes"\n')
	assert ed == []
	_, eu := isotp_unwalked_of('rx_id = 0x7E0\ntx_id = 0x7E8\next = "yes"\n')
	assert eu == ['[isotp] ext must be a boolean (true: the ids are 29-bit)']
}

// ecucheck's two passes — the schema walk, then ecumodel.validate — refuse a key of the wrong
// type ONCE: every [isotp] / [[doip.route]] row this reader judges (own_check) is walked for its
// type, and the reader leaves the type to the walk (cfgschema Key.own_check: said once)
fn test_a_wrong_typed_addressing_key_is_refused_once_by_ecucheck() {
	gate := fn (src string) []string {
		doc := toml.parse_text(src) or { panic(err) }
		mut errs := cfgschema.ecu.check(doc.to_any().as_map())
		errs << validate(doc)
		return errs
	}
	normal := '[isotp]\nbus = "can0"\n'
	fixed := '[isotp]\nbus = "can0"\naddressing = "normal_fixed"\n'
	route := '[doip]\naddress = "192.168.0.2"\nlogical_address = 0x10\n\n[[doip.route]]\nnode = "zone"\nlogical = 0x07C0\nbus = "can1"\n'
	// (base, the key's line as it should be, the same key mistyped)
	for c in [
		[normal + 'tx_id = 0x7E8\n', 'rx_id = 0x7E0\n', 'rx_id = "0x7E0"\n'],
		[normal + 'rx_id = 0x7E0\n', 'tx_id = 0x7E8\n', 'tx_id = "0x7E8"\n'],
		[normal + 'rx_id = 0x7E0\ntx_id = 0x7E8\n', 'functional_id = 0x7DF\n', 'functional_id = "0x7DF"\n'],
		[normal + 'rx_id = 0x7E0\ntx_id = 0x7E8\n', 'ext = true\n', 'ext = 1\n'],
		[normal + 'rx_id = 0x7E0\ntx_id = 0x7E8\n', 'addressing = "normal"\n', 'addressing = 5\n'],
		[fixed + 'ta = 0xF1\n', 'sa = 0x10\n', 'sa = "0x10"\n'],
		[fixed + 'sa = 0x10\n', 'ta = 0xF1\n', 'ta = "x"\n'],
		[fixed + 'sa = 0x10\nta = 0xF1\n', 'functional_ta = 0x33\n', 'functional_ta = 0.5\n'],
		[route + 'rx_id = 0x7C8\n', 'tx_id = 0x7C0\n', 'tx_id = "x"\n'],
		[route + 'tx_id = 0x7C0\n', 'rx_id = 0x7C8\n', 'rx_id = "x"\n'],
		[route + 'tx_id = 0x7C0\nrx_id = 0x7C8\n', 'ext = true\n', 'ext = 1\n'],
	] {
		good := gate(c[0] + c[1])
		bad := gate(c[0] + c[2])
		new := bad.filter(it !in good)
		assert new.len == 1, '${c[2].trim_space()}: ${new}'
	}
}

fn test_a_diag_allocation_is_read_by_the_same_rule() {
	// no allocation at all is no error: req and rsp are optional in a diag
	a, ea := diag_of('logical = 0x07C0\n')
	assert ea == [] && a.rx == 0 && a.tx == 0
	b, eb := diag_of('req = 0x7A0\nrsp = 0x7A8\n')
	assert eb == [] && b.rx == 0x7A0 && b.tx == 0x7A8 && !b.ext
	c, ec := diag_of('addressing = "normal_fixed"\nsa = 0x10\nta = 0xF1\nfunctional_ta = 0x33\n')
	assert ec == []
	assert c.rx == 0x18DA10F1 && c.tx == 0x18DAF110 && c.functional == 0x18DB33F1 && c.ext
	_, ed := diag_of('req = 0x800\nrsp = 0x7A8\n')
	assert ed == ['node "n" diag req 0x800 must be a standard 11-bit id (<= 0x7FF) — ext = true makes it 29-bit']
	_, ee := diag_of('addressing = "normal_fixed"\nsa = 0x10\nta = 0xF1\nreq = 0x7A0\n')
	assert has(ee, 'req is given with addressing = "normal_fixed"')
	f, ef := diag_of('req = 0x18DA10F1\nrsp = 0x18DAF110\next = true\n')
	assert ef == [] && f.ext && !f.fixed
	// system.toml is never walked: the reader says a wrong type itself
	_, eg := diag_of('req = "0x7A0"\nrsp = 0x7A8\next = 1\n')
	assert eg == ['node "n" diag ext must be a boolean (true: the ids are 29-bit)',
		'node "n" diag req must be an integer']
	_, eh := diag_of('addressing = "normal_fixed"\nsa = 0x10\nta = true\n')
	assert eh == ['node "n" diag ta must be an integer']
}

fn test_a_routes_ids_follow_its_ext() {
	route := fn (body string) []string {
		doc := toml.parse_text('[doip]\naddress = "192.168.0.2"\nlogical_address = 0x10\n\n[[doip.route]]\nnode = "zone"\nlogical = 0x07C0\nbus = "can1"\n' +
			body) or { panic(err) }
		return route_id_errors(doc)
	}
	assert route('tx_id = 0x7C0\nrx_id = 0x7C8\n') == []
	assert route('tx_id = 0x800\nrx_id = 0x7C8\n') == [
		'[[doip.route]] "zone" tx_id 0x800 must be a standard 11-bit id (<= 0x7FF) — ext = true makes it 29-bit',
	]
	assert route('tx_id = 0x18DA20F1\nrx_id = 0x18DAF120\next = true\n') == []
	assert route('tx_id = 0x20000000\nrx_id = 0x18DAF120\next = true\n') == [
		'[[doip.route]] "zone" tx_id = 0x20000000 is out of range (0x0..0x1fffffff)',
	]
	// a missing or non-integer id, and an ext that is not a boolean, are the schema walk's
	assert route('tx_id = 0x7C0\nrx_id = 0x7C8\next = 1\n') == []
	assert route('rx_id = 0x7C8\n') == []
	assert route('tx_id = "x"\nrx_id = 0x7C8\n') == []
}
