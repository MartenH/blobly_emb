module cfgschema

import comm.uds
import comm.fault
import comm.param

// the diagnostic tables of ecu.toml: the server ([isotp], [uds], [doip]), its data ([[did]],
// [[param]]) and its fault memory ([[fault]], [fault_memory]) — docs/diagnostics.md
fn ecu_diag_tables() []Table {
	return [
		tbl('isotp', '[isotp]', "The diagnostic server's ISO 15765-2 connection on CAN (docs/diagnostics.md).", [
			req('bus', .str).doc('the CAN bus ([bus.*] name) the connection runs on'),
			req('rx_id', .int).range(0, 0x7FF).hex().doc('the CAN id physical requests arrive on (11-bit)'),
			req('tx_id', .int).range(0, 0x7FF).hex().doc('the CAN id responses are sent on (11-bit)'),
			k('bs', .int).d('0').doc('the block size granted in our Flow Control (0 = the whole message at once)'),
			k('stmin_ms', .int).d('0').doc('the STmin (ms) we ask a sender to keep between consecutive frames'),
			k('functional_id', .int).range(0, 0x7FF).hex().doc('the functional (broadcast) request id, e.g. 0x7DF, single frames only; absent = none'),
		]),
		tbl('uds', '[uds]', "The node's one ISO 14229 diagnostic server: session and security timing, the 0x27 key, the service table.", [
			k('s3_ms', .int).d('${uds.default_s3_us / 1000}').doc('the session timeout back to the default session (ms; 0 = the default)'),
			k('security_attempts', .int).d('${uds.default_sa_attempts}').range(0, 255).doc('wrong 0x27 keys before the lockout (0 = the default)'),
			k('security_delay_ms', .int).d('${uds.default_sa_delay_us / 1000}').doc('the 0x27 lockout delay after too many wrong keys (ms; 0 = the default)'),
			k('security_key', .str).one_of(['reference']).doc('"reference" = blobly_net\'s PUBLIC bench key (a target); absent = the OEM\'s diag_sa_key_ok'),
			sub('services', .namedmap, 'uds_service').doc('the service table, "0xSID" = { ... } ("0x10 02": the [boot] handoff); absent = every service the build performs'),
		]),
		tbl('uds_service', '[uds] services row', 'One served service: the sessions it is accepted in and the 0x27 level it needs.', [
			k('sessions', .str_arr).one_of(session_names()).doc("the sessions it is accepted in; absent = the service's default sessions"),
			k('security', .int).d('0').range(0, uds.max_security_level).doc('the 0x27 level that must be unlocked first (0 = none)'),
		]),
		tbl('doip', '[doip]', "The diagnostic server over DoIP (ISO 13400) too — ThreadX target; one parser for this and a system node's `doip` (tools/doipcfg).", doip_ecu_keys()),
		tbl('did', '[[did]]', 'A data identifier the server reads (0x22) and may write (0x2E). Its value is ONE of: `ascii` / `bytes` (a constant), `signal` (live), `param` (a coded [[param]]), `param_status`, `tx_saturations`.', [
			req('id', .int).range(0, 0xFFFF).hex().doc('the 16-bit data identifier (0 is skipped)'),
			k('ascii', .str).doc('a constant value as an ASCII string (at most ${uds.max_did_data} bytes)'),
			k('bytes', .str).doc('a constant value as space-separated hex bytes (at most ${uds.max_did_data})'),
			k('writable', .boolean).d('false').doc("0x2E may overwrite the constant's RAM copy (implied by `write`)"),
			k('signal', .str).doc("a live value: the signal's, refreshed every pass, big-endian at its width; read-only"),
			k('param', .str).doc('the [[param]] this DID codes (0x2E) and reads back (0x22)'),
			k('param_status', .boolean).d('false').doc('one byte per [[param]]: 0 default / 1 coded / 2 reverted'),
			k('tx_saturations', .boolean).d('false').doc('the count of sent values saturated to their DBC range since start (u32 BE)'),
			sub('read', .tbl, 'did_access').doc('the 0x22 gate; absent = every session, no security'),
			sub('write', .tbl, 'did_access').doc('the 0x2E gate (makes the DID writable); absent = every session, no security'),
		]),
		tbl('did_access', '[[did]] read/write', 'The sessions and the 0x27 level an access needs.', [
			k('session', .str_arr).one_of(session_names()).doc('the sessions it is allowed in; absent = every session'),
			k('security', .int).d('0').range(0, uds.max_security_level).doc('the 0x27 level that must be unlocked (0 = none)'),
		]),
		tbl('param', '[[param]]', 'A coded parameter (variant coding): a read-only FB input, coded with 0x2E on its [[did]] and kept in the NvM journal (docs/diagnostics.md §3.4).', [
			req('name', .str).doc('PascalCase; the value type the FBs read'),
			sub('fields', .str_map, '').required().doc('1..${param.max_fields} fields, name -> bool / u8 / u16 / u32 / i8 / i16 / i32'),
			sub('default', .val_map, '').required().doc("every field's compiled default, within its range — what an uncoded vehicle runs"),
			sub('range', .namedmap, 'param_range').doc("per field, the values it may be coded to; absent = the type's"),
			k('apply', .str).d('"next_dispatch"').one_of(['next_dispatch', 'reset']).doc("when a coded value takes effect: the FB's next dispatch, or the next start"),
			k('version', .int).d('0').range(0, 255).doc("bump when a field's meaning changes but its type does not (stored values revert)"),
			k('nvm_id', .int).d('0').range(0, 65534).doc('pins the journal block (0 = derived; only to resolve a reported collision)'),
		]),
		tbl('param_range', '[[param]] range', 'The coded values one field may take (0x2E answers 0x31 outside it).', [
			k('min', .int).doc("the lowest value (default: the type's minimum)"),
			k('max', .int).doc("the highest value (default: the type's maximum)"),
		]),
		tbl('fault', '[[fault]]', 'A diagnostic fault: a DTC, the test that sets it and how its results are debounced, confirmed and aged (docs/diagnostics.md §3.3).', [
			req('name', .str).doc("PascalCase, unique; a field of the testing FB's Faults struct"),
			req('dtc', .int).range(1, 0xFFFFFF).hex().doc('the 3-byte DTC 0x19 reports; unique per server'),
			k('from', .str).doc('"Fb.handler" — the handler that tests it (or `signal` + `on` for a signal-status fault)'),
			k('signal', .str).doc('a signal-status fault: the received signal whose rx status the bridge watches'),
			k('on', .str).one_of(['timeout', 'integrity', 'lost']).doc('a signal-status fault: the rx status that counts as failed'),
			sub('debounce', .tbl, 'fault_debounce').doc('how test results become failed / passed; absent = counter, fail 1, pass 1'),
			k('enable', .str_arr).d('[]').doc('"Signal.field" bool conditions (read by the handler) that must hold for a result to count'),
			k('confirm', .int).d('1').range(1, 255).doc('failed operation cycles to confirm the DTC'),
			k('aging', .int).d('0').range(0, 255).doc('passing cycles before a confirmed DTC ages out (0 = never)'),
			k('freeze', .int_arr).d('[]').doc('the snapshot: [[did]] ids captured at the failure, 0x19 04 (at most ${fault.max_freeze})'),
			k('priority', .int).d('128').range(1, 255).doc('displacement when the snapshot entries are full: 1 (most important) .. 255'),
			k('snapshot_id', .int).doc('retired: refused, with the move to `snapshot_ids`'),
			k('snapshot_ids', .int_arr).range(1, 0xFFFE).hex().doc("pins the snapshot's two journal blocks [A, B] (only to resolve a reported collision)"),
		]),
		tbl('fault_debounce', '[[fault]] debounce', 'A counter debounce counts results; a time debounce times them. Each kind takes only its own keys.', [
			k('kind', .str).d('"counter"').one_of(['counter', 'time']).doc('count results, or time them'),
			k('fail', .int).d('1').range(1, 0xFFFF).doc('counter: the failed-result threshold'),
			k('pass', .int).d('1').range(1, 0xFFFF).doc('counter: the passed-result threshold'),
			k('fail_ms', .int).range(1, 2147483).doc('time: how long it keeps failing before it is failed (ms; required)'),
			k('pass_ms', .int).range(1, 2147483).doc('time: how long it keeps passing before it is passed (ms; required)'),
			k('inc', .int).d('1').range(1, 0xFFFF).doc('counter: the step per failed result'),
			k('dec', .int).d('1').range(1, 0xFFFF).doc('counter: the step per passed result'),
			k('jump', .boolean).doc('counter: reset on a reversal ("N in a row"); default true when fail = 1, else it accumulates'),
		]),
		tbl('fault_memory', '[fault_memory]', 'The fault memory as a whole.', [
			k('cycle', .str).doc('the operation cycle: a bool "Signal.field", or "power"; absent on a target = NM'),
			k('entries', .int).range(1, fault.max_entries).doc('snapshot entries (default one per fault with `freeze`); fewer = displacement'),
		]),
	]
}

// session_names: the UDS sessions a gate may name (comm/uds session bits)
// (a function, not a const: the schema consts are built from it, and V does not order a const's
// initialisation after the consts a function it calls reads)
pub fn session_names() []string {
	return ['default', 'extended', 'programming', 'safety']
}

fn doip_ecu_keys() []Key {
	mut keys := [
		req('address', .str).doc("the node's static IPv4 address — a host of its subnet (not its network, broadcast or gateway address — on the default /24: not .0, .1 or .255)"),
		k('netmask', .str).ipv4().d('"255.255.255.0"').doc('the subnet mask the node is brought up on, application and bootloader alike; contiguous, /1../30 (equal to the eth bus\'s, where the node has one)'),
		k('gateway', .str).ipv4().doc('the default gateway; inside address/netmask and not its network or broadcast address. Absent = the subnet\'s first host, (address & netmask) | 1'),
	]
	for key in doip_entity_keys('logical_address', 'functional_address') {
		keys << match key.name {
			'logical_address' { key.required() }
			'functional_address' { key.or_zero() } // [doip] reads 0 as the default
			else { key }
		}
	}
	return keys
}
