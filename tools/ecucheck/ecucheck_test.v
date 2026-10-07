module main

import toml
import tools.cfgschema

// @verifies REQ-DIAG-017
// ecucheck's schema walk: an entry of a named-table map ([[param]] range, [bus.*], [uds] services)
// must itself be a table — a bare value would be checked as an empty table and pass.

fn errors_of(src string) []string {
	doc := toml.parse_text(src) or { panic(err) }
	return cfgschema.ecu.check(doc.to_any().as_map())
}

const param_src = '
[[param]]
name    = "SteerLimit"
fields  = { deg = "u16" }
default = { deg = 360 }
range   = { deg = { min = 0, max = 360 } }
version = 1
'

fn test_a_param_range_entry_must_be_a_table() {
	assert errors_of(param_src) == []string{}
	bad := errors_of(param_src.replace('range   = { deg = { min = 0, max = 360 } }', 'range   = { deg = 100 }'))
	assert bad.any(it.contains('"deg" must be a table')), bad.str()
	bad2 := errors_of(param_src.replace('range   = { deg = { min = 0, max = 360 } }', 'range   = 100'))
	assert bad2.len > 0, 'a scalar range passed'
}

fn test_a_bus_entry_must_be_a_table() {
	assert errors_of('[bus]\ncan0 = 5\n').any(it.contains('"can0" must be a table'))
}
