module cfgschema

import comm.doip
import comm.isotp
import comm.uds
import comm.fault
import comm.param

// the diagnostic tables of ecu.toml: the server ([isotp], [uds], [doip]), its data ([[did]],
// [[param]]) and its fault memory ([[fault]], [fault_memory]) — docs/diagnostics.md
fn ecu_diag_tables() []Table {
	return [
		tbl('isotp', '[isotp]', "The diagnostic server's ISO 15765-2 connection on CAN (docs/diagnostics.md).", [
			req('bus', .str).doc('the CAN bus ([bus.*] name) the connection runs on'),
			k('addressing', .str).d('"normal"').one_of(addressing_formats()).own_check().doc('how the ids are stated (docs/can-tp.md §2): "normal" gives rx_id / tx_id (11-bit, or 29-bit with ext); "normal_fixed" gives sa / ta, from which the 29-bit ids derive (ISO 15765-2 normal fixed addressing, priority 6). Extended and mixed addressing are not supported'),
			k('rx_id', .int).range(0, i64(isotp.ext_id_max)).hex().own_check().doc('the CAN id physical requests arrive on: 11-bit (0x000..0x7FF) unless ext; required with normal addressing (a dissolved node\'s [isotp] that states no ids takes its system diag, lowered by sysgen), refused with normal_fixed'),
			k('tx_id', .int).range(0, i64(isotp.ext_id_max)).hex().own_check().doc('the CAN id responses are sent on: 11-bit (0x000..0x7FF) unless ext; required with normal addressing (a dissolved node\'s [isotp] that states no ids takes its system diag, lowered by sysgen), refused with normal_fixed'),
			k('ext', .boolean).d('false').own_check().doc('normal addressing: rx_id, tx_id and functional_id are 29-bit identifiers (0x00000000..0x1FFFFFFF), frames received and sent with the extended id; false = 11-bit. Refused with normal_fixed (always 29-bit)'),
			k('sa', .int).range(0, 255).hex().own_check().doc('normal_fixed: this node\'s own address — the target address of the requests it receives (0x18DA<sa><ta>) and the source address of its answers (0x18DA<ta><sa>); required there, refused with normal'),
			k('ta', .int).range(0, 255).hex().own_check().doc('normal_fixed: the tester\'s address (e.g. 0xF1) — the source address of the requests and the target address of the answers; not sa; required there, refused with normal'),
			k('functional_ta', .int).range(0, 255).hex().own_check().doc('normal_fixed: the functional target address (conventionally 0x33, ISO 15765-4) — functional requests arrive on 0x18DB<functional_ta><ta>; absent = none; refused with normal'),
			k('bs', .int).d('0').range(0, 255).doc('the block size granted in our Flow Control, one byte on the wire (0 = the whole message at once)'),
			k('stmin_ms', .int).d('0').range(0, 127).doc('the STmin (ms) we ask a sender to keep between consecutive frames; ISO 15765-2 encodes milliseconds only up to 127'),
			k('functional_id', .int).range(0, i64(isotp.ext_id_max)).hex().own_check().doc('the functional (broadcast) request id, e.g. 0x7DF, single frames only: 11-bit unless ext; absent (or 0) = none; refused with normal_fixed (functional_ta). A dissolved node\'s [isotp] that takes its system diag may state it beside a normal-addressing one, read in the allocation\'s format (with an ext only where it agrees)'),
			k('max_message', .int).d('${isotp.default_message}').range(isotp.min_message, isotp.message_limit).doc('the longest diagnostic message either way, in bytes (the escape first frame above 4095 is not supported). It sizes the server\'s buffers and response capacity, the DoIP entity\'s message limit, a gateway\'s routed messages and the bootloader\'s TransferData block; generation refuses one smaller than the largest message the configuration determines'),
			k('tx_dl', .int).d('8').one_of_ints(tx_dls()).doc('the frame length (TX_DL) the connection transmits with, in bytes: ${tx_dl_list()}. Above 8 only on a CAN-FD bus ([bus.*] fd = true): single frames of up to TX_DL - 2 bytes behind the escape, consecutive frames of TX_DL - 1. Frames of any length are received without it; the bootloader and a gateway\'s route to the node send with it too (REQ-CAN-TP-026)'),
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
		tbl('doip_route', '[[doip.route]]', 'A node behind this DoIP gateway that diagnostic messages to its logical address are routed to (REQ-NET-019) — sysgen lowers them from system.toml (a gateway\'s doip `routes`, each routed node\'s diag).', [
			req('node', .str).doc('the routed node (named in refusals and the generated code)'),
			req('logical', .int).hex().doc('its DoIP logical address (0x0001..0x0DFF or 0x1000..0x7FFF); not this entity\'s own or its functional address'),
			req('bus', .str).doc('the CAN bus ([bus.*] name) it is on'),
			req('tx_id', .int).range(0, i64(isotp.ext_id_max)).hex().own_check().doc('its physical request id: what the gateway sends on (11-bit unless ext)'),
			req('rx_id', .int).range(0, i64(isotp.ext_id_max)).hex().own_check().doc('its response id: what the gateway receives on (11-bit unless ext)'),
			k('ext', .boolean).d('false').own_check().doc('the routed node\'s ids are 29-bit identifiers (its 29-bit or normal fixed addressing): the gateway sends and receives them with the extended id (REQ-NET-021); sysgen writes it from the node\'s diag'),
			k('max_message', .int).d('${isotp.default_message}').range(isotp.min_message, isotp.message_limit).doc('its [isotp] max_message: the gateway refuses a longer routed request at once (diagnostic NACK 0x04) rather than forward one the node would refuse on its bus (REQ-CAN-TP-023); sysgen writes it when the node\'s is not the default'),
			k('tx_dl', .int).d('8').one_of_ints(tx_dls()).doc('its [isotp] tx_dl: the frame length the gateway sends to it with (${tx_dl_list()}; above 8 only on a CAN-FD bus); sysgen writes it when the node\'s is not 8, and syscheck refuses an authored route whose tx_dl is not its node\'s (REQ-CAN-TP-026)'),
		]),
		tbl('did', '[[did]]', 'A data identifier the server reads (0x22) and may write (0x2E). Its value is ONE of: `ascii` / `bytes` (a constant), `signal` (live), `param` (a coded [[param]]), `param_status`, `tx_saturations`. A live signal\'s DID may also carry a `control` (0x2F).', [
			req('id', .int).range(0, 0xFFFF).hex().doc('the 16-bit data identifier (0 is skipped)'),
			k('ascii', .str).doc('a constant value as an ASCII string (at most ${uds.max_did_data} bytes)'),
			k('bytes', .str).doc('a constant value as space-separated hex bytes (at most ${uds.max_did_data})'),
			k('writable', .boolean).d('false').doc("0x2E may overwrite the constant's RAM copy with a record of exactly its size (implied by `write`)"),
			k('signal', .str).doc("a live value: the signal's, refreshed every pass, big-endian at its width; read-only"),
			k('param', .str).doc('the [[param]] this DID codes (0x2E, a record of exactly its width) and reads back (0x22)'),
			k('param_status', .boolean).d('false').doc('one byte per [[param]]: 0 default / 1 coded / 2 reverted'),
			k('tx_saturations', .boolean).d('false').doc('the count of sent values saturated to their DBC range since start (u32 BE)'),
			sub('read', .tbl, 'did_access').doc('the 0x22 gate; absent = every session, no security'),
			sub('write', .tbl, 'did_access').doc('the 0x2E gate (makes the DID writable; a record of exactly its size); absent = every session, no security'),
			sub('control', .tbl, 'did_control').doc('0x2F InputOutputControlByIdentifier on the `signal` this DID reads: a tester\'s value replaces the signal where the node encodes it into its frame (docs/diagnostics.md §3.1); absent = no control'),
		]),
		tbl('did_control', '[[did]] control', 'An input/output control (0x2F) of the output signal a live DID reads: the parameters served beside returnControlToECU, and the gate.', [
			req('parameters', .str_arr).one_of(['reset_to_default', 'freeze_current_state', 'short_term_adjustment']).doc('the control parameters served besides returnControlToECU (always served): reset to the signal\'s initial value, freeze the value published now, a value of the tester\'s'),
			k('session', .str_arr).d('["extended"]').one_of(['extended', 'safety']).doc('the sessions it is accepted in (never default or programming)'),
			k('security', .int).d('0').range(0, uds.max_security_level).doc('the 0x27 level that must be unlocked; 0 = the [uds] services 0x2F row\'s level (none if the row names none). The control is returned when that level is relocked'),
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
		tbl('routine', '[[routine]]', 'A RoutineControl (0x31) routine, run by the FB handler that reads its `<Name>Request` and writes its `<Name>Result`; answered responsePending (0x78) while it runs (docs/diagnostics.md §3.1).', [
			req('id', .int).range(0, 0xFFFF).hex().doc('the 16-bit routineIdentifier: 0x0200..0xDFFF or 0xF000..0xFEFF, unique; not the bootloader\'s 0xFF00 / 0xFF01 on a [boot] node'),
			req('name', .str).doc('PascalCase, unique; the FB names `<name>Request` in its handler\'s reads and `<name>Result` in its writes'),
			k('mode', .str).d('"sync"').one_of(['sync', 'async']).doc('sync: 0x31 01 is answered when the routine completes; async: once the FB has accepted it (running), 03 reads its progress'),
			k('stop', .boolean).d('false').doc('0x31 02 stopRoutine is offered (async only)'),
			k('results', .boolean).d('false').doc('0x31 03 requestRoutineResults is offered'),
			k('start_in', .int).d('0').range(0, uds.max_routine_record).doc('the option record bytes a start carries (exactly; another length is 0x13)'),
			k('start_out', .int).d('0').range(0, uds.max_routine_record).doc("the record bytes the start's answer carries"),
			k('results_out', .int).d('0').range(0, uds.max_routine_record).doc("the record bytes 03's answer carries (needs `results`)"),
			k('timeout_ms', .int).d('${uds.default_routine_timeout_us / 1000}').range(100, 100000).doc('a start or stop its FB has not answered by then is answered 0x22 and the FB asked to stop'),
			k('sessions', .str_arr).d('["extended"]').one_of(['default', 'extended', 'safety']).doc('the sessions it may be started, stopped and read in'),
			k('security', .int).d('0').range(0, uds.max_security_level).doc('the 0x27 level that must be unlocked (0 = none)'),
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

// addressing_formats: the ISO 15765-2 addressing formats a diagnostic connection may state its ids
// in ([isotp] addressing, a system node's diag `addressing`); extended and mixed addressing are not
// supported. (A function, not a const: the schema consts are built from it.)
pub fn addressing_formats() []string {
	return ['normal', 'normal_fixed']
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
	keys << sub('route', .arr, 'doip_route').doc('a gateway\'s routes: the nodes behind it diagnostic messages are forwarded to (at most ${doip.max_routes})')
	for key in doip_entity_keys('logical_address', 'functional_address') {
		keys << match key.name {
			'logical_address' { key.required() }
			'functional_address' { key.or_zero() } // [doip] reads 0 as the default
			else { key }
		}
	}
	return keys
}

// tx_dls: the frame lengths ISO-TP transmits with, as isotp.valid_dl states them — the values
// [isotp] tx_dl and [[doip.route]] tx_dl take, so the schema check, the generated reference and
// the JSON Schema refuse what generation refuses
pub fn tx_dls() []i64 {
	mut dls := []i64{}
	for dl in 0 .. 65 {
		if isotp.valid_dl(dl) {
			dls << i64(dl)
		}
	}
	return dls
}

// tx_dl_list: tx_dls as a sentence reads them ("8, 12, 16, 20, 24, 32, 48 or 64")
pub fn tx_dl_list() string {
	dls := tx_dls().map(it.str())
	return dls[..dls.len - 1].join(', ') + ' or ' + dls.last()
}
