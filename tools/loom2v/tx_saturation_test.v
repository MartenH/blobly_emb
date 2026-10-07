module main

import os
import time

// @verifies REQ-COM-010
// A sent value outside its DBC signal's range is saturated by the generated `_set` (com.encode_raw,
// tested in comm/com and, as generated code, in tools/dbc2cfg) — here, that every sender goes
// through it and counts what it saturated, and that the `tx_saturations` DID reads the count: the
// host bridge's own sends and its gateway signal routes (the target comm thread's producers are
// pinned in rx_target_test.v, beside its fixture).

const ts_bin = os.join_path(os.temp_dir(), 'loom2v_tx_sat_${os.getpid()}_${time.now().unix_nano()}')

const ts_did = '
[[did]]
id             = 0x0120
tx_saturations = true
'

fn testsuite_begin() {
	r := os.execute('${@VEXE} -enable-globals -o ${ts_bin} ${os.join_path(@VMODROOT, 'tools',
		'loom2v')}')
	assert r.exit_code == 0, r.output
}

fn testsuite_end() {
	os.rm(ts_bin) or {}
}

// ts_generate runs loom2v on example `ex` (its ecu.toml edited, `extra` appended) and its DBC.
fn ts_generate(name string, ex string, edit fn (string) string, extra string) (int, string, string) {
	tmp := os.join_path(os.temp_dir(), 'tx_sat_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	os.mkdir_all(tmp) or { panic(err) }
	src := os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	os.write_file(ecu, edit(src) + extra) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${ts_bin} ${ecu} ${os.join_path(ex, 'bus.dbc')} ${os.join_path(tmp, 'sig.v')} ' +
		'${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }
}

fn same(src string) string {
	return src
}

fn example(name string) string {
	return os.join_path(@VMODROOT, 'examples', name)
}

// the DID record: the count, big-endian, written into the server's table after the pass's sends
fn did_writes(srv string, count string) string {
	return '${srv}.dids[5].data[0] = u8(${count} >> 24)'
}

fn test_the_host_bridge_counts_what_it_saturates_and_the_did_reads_it() {
	code, out, glue := ts_generate('host', example('overspeed'), same, ts_did)
	assert code == 0, out
	assert glue.contains('\ttx_sat com.TxSaturations'), glue
	// each value through the generated `_set`, its saturation noted, counted once the frame is sent
	assert glue.contains('if lamp_frame_warn_lamp_set(mut tx_lamp_frame.data, '), glue
	assert glue.contains('tx_lamp_frame_sat++')
	assert glue.contains('st.tx_sat.add(tx_lamp_frame_sat)')
	// the DID (the sixth in overspeed's table) holds the count
	assert glue.contains(did_writes('st.conn_diag.server', 'st.tx_sat.count')), glue
	assert glue.contains('st.conn_diag.server.dids[5].len = 4')
}

fn test_a_gateway_signal_route_counts_too() {
	isotp := '
[isotp]
bus   = "can0"
rx_id = 0x7B0
tx_id = 0x7B8
'
	code, out, glue := ts_generate('route', example('gw_signal'), same, isotp + ts_did)
	assert code == 0, out
	assert glue.contains('if dst_frame_speed_set(mut rf_can1_dst_frame.data, st.'), glue
	assert glue.contains('st.tx_sat.add(rf_can1_dst_frame_sat)')
	assert glue.contains('st.conn_')
}

// On the host each bus bridge counts its own: a DID on one bridge cannot read another's count, so
// a node whose sent values are encoded by a bridge that serves no diagnostic connection is refused.
fn test_the_host_refuses_a_did_that_cannot_read_every_count() {
	isotp := '
[isotp]
bus   = "can1"
rx_id = 0x7B0
tx_id = 0x7B8
'
	code, out, _ := ts_generate('split', example('gw_signal'), same, isotp + ts_did)
	assert code != 0
	assert out.contains('bus "can0" encodes sent values, but its bridge serves no diagnostic connection'), out
}

fn test_the_did_is_the_nodes_alone() {
	for k, v in {
		'bytes':    '"00"'
		'signal':   '"Speed"'
		'writable': 'true'
	} {
		code, out, _ := ts_generate('key_${k}', example('overspeed'), same, ts_did + '${k} = ${v}\n')
		assert code != 0, k
		assert out.contains('is the count of saturated sent values, which the node keeps and a tester only reads — `${k}`'), out
	}
	code, out, _ := ts_generate('twice', example('overspeed'), same, ts_did +
		ts_did.replace('0x0120', '0x0121'))
	assert code != 0
	assert out.contains('2 [[did]]s are the count of saturated sent values'), out
}
