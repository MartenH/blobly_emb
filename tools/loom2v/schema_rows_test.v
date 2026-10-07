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
