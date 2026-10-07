module cfgschema

import toml
import tools.doipcfg

// The schema is data, so what it says about itself is checkable: every reference resolves, every
// default is a legal value of its own key, and the two parsers that keep their own key lists
// (doipcfg's policy) agree with it.
fn test_every_sub_table_resolves_and_every_table_is_reachable() {
	for s in [ecu, system] {
		mut ctxs := map[string]bool{}
		for t in s.tables {
			assert t.ctx !in ctxs, '${s.file}: table "${t.ctx}" twice'
			ctxs[t.ctx] = true
			mut names := map[string]bool{}
			for key in t.keys {
				assert key.name !in names, '${s.file} ${t.ctx}: key "${key.name}" twice'
				names[key.name] = true
				if key.typ in [.tbl, .arr, .namedmap] {
					assert s.has_table(key.sub), '${s.file} ${t.ctx}.${key.name}: no table "${key.sub}"'
				} else {
					assert key.sub == '', '${s.file} ${t.ctx}.${key.name}: a ${key.typ} has no sub-table'
				}
				assert key.desc != '', '${s.file} ${t.ctx}.${key.name} has no description'
			}
		}
		assert s.ordered().len == s.tables.len, '${s.file}: a table nothing names'
	}
}

fn test_values_are_stated_only_where_they_mean_something() {
	for s in [ecu, system] {
		for t in s.tables {
			for key in t.keys {
				if key.choices.len > 0 {
					assert key.typ in [.str, .str_arr], '${t.ctx}.${key.name}: choices on a ${key.typ}'
				}
				if key.ranged {
					assert key.typ in [.int, .int_arr, .id], '${t.ctx}.${key.name}: a range on a ${key.typ}'
					assert key.min <= key.max, '${t.ctx}.${key.name}: empty range'
				}
			}
		}
	}
}

// a default is what the key reads as when absent, so it must be a value the key accepts
fn test_every_default_is_a_legal_value() {
	for s in [ecu, system] {
		for t in s.tables {
			for key in t.keys {
				if key.def == '' {
					continue
				}
				doc := toml.parse_text('v = ${key.def}') or {
					assert false, '${t.ctx}.${key.name}: default `${key.def}` is not TOML'
					continue
				}
				v := doc.value('v')
				assert type_ok(v, key.typ), '${t.ctx}.${key.name}: default `${key.def}` is not ${type_name(key.typ)}'
				if key.choices.len > 0 && v is string {
					assert v in key.choices, '${t.ctx}.${key.name}: default ${key.def} is not one of its choices'
				}
				if key.ranged && v is i64 {
					assert key.in_range(v), '${t.ctx}.${key.name}: default ${key.def} is outside its range'
				}
			}
		}
	}
}

fn test_the_doip_policy_keys_are_doipcfgs() {
	policy := doipcfg.keys()
	ecu_keys := ecu.table('doip').names()
	sys_keys := system.table('sys_doip').names()
	assert ecu_keys[ecu_keys.len - policy.len..] == policy
	assert sys_keys[sys_keys.len - policy.len..] == policy
	assert sys_keys[..sys_keys.len - policy.len] == ['logical', 'functional']
}

fn errs_of(src string) []string {
	doc := toml.parse_text(src) or { panic(err) }
	return ecu.check(doc.to_any().as_map())
}

fn test_check_names_the_table_the_key_and_the_fix() {
	e := errs_of('[trace]\nlevl = "fb"\n')
	assert e.len == 1
	assert e[0].starts_with('[trace]: unknown key "levl" — did you mean "level"? (allowed: enabled, bus, level,'), e[0]
	assert errs_of('[trace]\npre_pct = "50"\n') == [
		'[trace] "pre_pct": expected an integer, got a string',
	]
	assert errs_of('[[bulk]]\nname = "a"\n').any(it == '[[bulk]]: missing required key "producer"')
	// a table-valued key of [nm] is a legacy [nm.<bus>] block, checked as one
	assert errs_of('[nm.can0]\nrx_lo = 1\nrx_hi = 2\n') == []
	assert errs_of('[nm.can0]\nrx_low = 1\n').any(it.starts_with('[nm.*]: unknown key "rx_low"'))
}

fn test_unknown_reports_only_the_typos() {
	doc := toml.parse_text('[bus.a]\ninterface = "can0"\nbitrat = 5\n[bus.a.nm]\npeers = [1, 2]\n') or {
		panic(err)
	}
	bus := doc.value('bus').as_map()['a'] or { panic('no bus') }
	assert system.unknown(bus.as_map(), 'sys_bus') == ['bitrat']
	nm := ecu.unknown({
		'can0': toml.Any(map[string]toml.Any{})
		'nod':  toml.Any(i64(1))
	}, 'nm')
	assert nm == ['nod']
}

// (no JSON parser here: vlib's x.json2 does not build on every V this repo is built with — the
// structure is checked by balance, the editors parse the real thing)
fn test_the_json_schemas_balance_and_are_closed() {
	for s in [ecu, system] {
		raw := s.json_schema()
		mut depth := 0
		mut in_str := false
		mut esc := false
		for c in raw {
			if in_str {
				if esc {
					esc = false
				} else if c == `\\` {
					esc = true
				} else if c == `"` {
					in_str = false
				}
				continue
			}
			match c {
				`"` {
					in_str = true
				}
				`{`, `[` { depth++ }
				`}`, `]` { depth-- }
				else {}
			}
			assert depth >= 0, s.file
		}
		assert depth == 0 && !in_str, s.file
		assert raw.count('"additionalProperties": false') + raw.count('"additionalProperties": {"\$ref"') >= s.tables.len
		for t in s.tables {
			if t.ctx != s.root {
				assert raw.contains('"${t.ctx}": {'), t.ctx
			}
		}
	}
}

fn test_the_reference_has_a_section_per_table() {
	md := markdown([ecu, system])
	for s in [ecu, system] {
		for t in s.tables {
			assert md.contains('<a id="${anchor(s, t.ctx)}"></a>'), t.ctx
		}
	}
}

fn test_check_refuses_a_value_outside_its_row() {
	assert errs_of('[target]\nkind = "threadX"\n') == [
		'[target] "kind": "threadX" is not one of "baremetal", "threadx"',
	]
	assert errs_of('[[signal]]\nname = "A"\nfields = { v = "u8" }\nfrom = "p"\nto = "q"\ntransport = "tripple"\n').len == 1
	assert errs_of('[isotp]\nbus = "can0"\nrx_id = 0x800\ntx_id = 0x7E8\n') == [
		'[isotp] "rx_id": 0x800 is outside 0x0..0x7FF',
	]
	assert errs_of('[[did]]\nid = 0xF190\nread = { session = ["extended", "factory"] }\n') == [
		'[[did]] read/write "session": "factory" is not one of "default", "extended", "programming", "safety"',
	]
	// 0 is [doip]'s spelling of the default functional address
	assert errs_of('[doip]\naddress = "192.168.0.2"\nlogical_address = 0x10\nfunctional_address = 0\n') == []
	assert errs_of('[doip]\naddress = "192.168.0.2"\nlogical_address = 0x10\nfunctional_address = 0x10\n').len == 1
	// an own_check row is ecumodel.validate's to judge (ecucheck runs both): said once, there
	assert errs_of('[trace]\npre_pct = 150\n') == []
}
