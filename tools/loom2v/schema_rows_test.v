module main

import tools.cfgschema

// The schema's enumerations that a generator MAPS rather than just checks: every value the schema
// offers must map, and the mapping must take nothing the schema does not offer — or the reference
// doc and the editors' JSON Schema would promise a value generation refuses (or hide one it takes).
fn test_the_session_names_are_the_ones_session_bit_maps() {
	for name in cfgschema.session_names() {
		session_bit(name) or { assert false, 'schema session "${name}" is not a session the server knows' }
	}
	session_bit('defualt') or { return }
	assert false, 'session_bit accepted a name the schema does not offer'
}

fn test_the_did_and_service_gates_share_the_session_names() {
	assert cfgschema.session_names().len == 4
	assert cfgschema.ecu.key('did_access', 'session').choices == cfgschema.session_names()
	assert cfgschema.ecu.key('uds_service', 'sessions').choices == cfgschema.session_names()
}

// a default the generator applies must be the one the schema documents
fn test_the_generator_defaults_are_the_schemas() {
	assert cfgschema.ecu.key('fault', 'priority').default_int() == default_fault_priority
	t := TraceCfg{}
	assert cfgschema.ecu.key('trace', 'level').def == '"${t.level}"'
	assert cfgschema.ecu.key('trace', 'mode').def == '"${t.mode}"'
	assert cfgschema.ecu.key('trace', 'buffer_records').default_int() == t.buffer_records
	assert cfgschema.ecu.key('trace', 'pre_pct').default_int() == t.pre_pct
	assert cfgschema.ecu.key('trace', 'push_ms').default_int() * 1000 == t.push_us
	assert cfgschema.ecu.key('trace', 'cmd').def == '0x${t.cmd_id:X}'
	assert cfgschema.ecu.key('trace', 'rsp').def == '0x${t.rsp_id:X}'
	assert cfgschema.ecu.key('trace', 'record').def == '0x${t.record_id:X}'
	assert cfgschema.ecu.key('trace', 'dump_fc').def == '0x${t.dump_fc_id:X}'
	a := WearAssume{}
	for key, v in {
		'cycles_per_day':          a.cycles
		'resets_per_day':          a.resets
		'clears_per_day':          a.clears
		'setting_changes_per_day': a.settings
		'codings_per_day':         a.codings
	} {
		assert cfgschema.ecu.key('nvm_assume', key).default_int() == v, key
	}
}
