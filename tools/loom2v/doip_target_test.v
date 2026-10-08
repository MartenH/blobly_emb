module main

import os

// [doip] (gen_doip.v): the node's one diagnostic server reachable over DoIP too — what the
// generator wires into the comm thread and boot, and what it refuses. Runs the real generator on
// testdata/threadx_node (a ThreadX node config, test input) with a connection and [doip] appended
// (a refusal is a panic, which cannot be caught in-process).
// @verifies REQ-NET-012 (the build half: no service that changes ECU state is reachable over IP
// without a security level — comm/diag's tests show the unlock that level asks for is the network's own)

const fixture_dir = os.join_path(@DIR, 'testdata', 'threadx_node')

// a service table gating the one state-changing service that config performs (0x11; no fault
// memory, so no 0x14/0x85), as every [doip] node must (REQ-NET-012)
const doip_uds = '
[uds.services]
"0x10" = {}
"0x11" = { sessions = ["extended"], security = 1 }
"0x22" = {}
"0x27" = {}
"0x2E" = {}
"0x3E" = {}
'

// the same table with the reset gated by session alone (and no 0x27: nothing would need it)
const doip_open_reset = doip_conn.replace('"0x11" = { sessions = ["extended"], security = 1 }',
	'"0x11" = { sessions = ["extended"] }').replace('"0x27" = {}\n', '')

const doip_conn = doip_uds + '
[isotp]
bus           = "can0"
rx_id         = 0x7B0
tx_id         = 0x7B8
functional_id = 0x7DF

[[did]]
id    = 0xF190
ascii = "BLOBLYH735THREADX"

[doip]
address         = "192.168.0.50"
logical_address = 0x07B0
'

fn doip_loom2v() string {
	bin := os.join_path(os.temp_dir(), 'loom2v_doip_target_${os.getpid()}')
	if !os.exists(bin) {
		r := os.execute('${@VEXE} -enable-globals -o ${bin} ${os.join_path(@VMODROOT, 'tools',
			'loom2v')}')
		assert r.exit_code == 0, r.output
	}
	return bin
}

// generate runs loom2v on the fixture's config with `extra` appended: exit code, output, glue
fn generate(name string, extra string) (int, string, string) {
	code, out, glue, _ := generate_mk(name, extra)
	return code, out, glue
}

// generate_mk is generate, with the gen/loom_build.mk it wrote
fn generate_mk(name string, extra string) (int, string, string, string) {
	tmp := os.join_path(os.temp_dir(), 'doip_target_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	ex := fixture_dir
	os.mkdir_all(tmp) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	src := os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) }
	os.write_file(ecu, src + extra) or { panic(err) }
	dbc := os.join_path(tmp, 'bus.dbc')
	os.cp(os.join_path(ex, 'bus.dbc'), dbc) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${doip_loom2v()} ${ecu} ${dbc} ${os.join_path(tmp, 'sig.v')} ' +
		'${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }, os.read_file(os.join_path(tmp,
		'loom_build.mk')) or { '' }
}

// generate_ecu runs loom2v on `ecu` alone (the fixture's DBC beside it)
fn generate_ecu(name string, ecu_text string) (int, string, string, string) {
	tmp := os.join_path(os.temp_dir(), 'doip_target_${name}_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	os.mkdir_all(tmp) or { panic(err) }
	ecu := os.join_path(tmp, 'ecu.toml')
	os.write_file(ecu, ecu_text) or { panic(err) }
	dbc := os.join_path(tmp, 'bus.dbc')
	os.cp(os.join_path(fixture_dir, 'bus.dbc'), dbc) or { panic(err) }
	glue := os.join_path(tmp, 'gen.v')
	r := os.execute('${doip_loom2v()} ${ecu} ${dbc} ${os.join_path(tmp, 'sig.v')} ' +
		'${os.join_path(tmp, 'ports.v')} ${glue} ${os.join_path(tmp, 'manifest.csv')}')
	return r.exit_code, r.output, os.read_file(glue) or { '' }, os.read_file(os.join_path(tmp,
		'loom_build.mk')) or { '' }
}

fn test_the_comm_thread_serves_doip_from_the_mailbox() {
	code, out, glue := generate('doip_ok', doip_conn)
	assert code == 0, out
	assert glue.contains('import comm.doip')
	for g in ['g_doip      doip.Server', 'g_doip_out  [doip.max_resp]u8', 'g_doip_resp [doip.max_uds]u8'] {
		assert glue.contains(g), g
	}
	// the TCP seed before the loop; each pass: housekeep, what the doip thread reported, then the
	// request in the mailbox — served by the ONE server, ahead of the CAN drain
	steps := [
		'C.doip_net_seed(doip_seed)',
		'g_diag.housekeep(',
		'// pass: remote', // the DoIP step of comm_pass_order, ahead of the drain
		'doipnet.serve_mailbox(mut g_diag, &g_doip_req[0], &g_doip_resp[0])',
		// a 0x28 that arrived over DoIP gates this pass's drain (R5)
		'st.rxg.sample(g_diag.server.rx_enabled()',
		'// pass: drain',
		'for ch.recv(mut rx) {',
	]
	mut at := -1
	for step in steps {
		i := glue[at + 1..].index(step) or {
			assert false, 'step "${step}" missing or out of order (after offset ${at})'
			return
		}
		at = at + 1 + i
	}
	// boot: the identity before any thread runs (DID 0xF190 is the VIN), then NetX; the IP thread
	// at the comm thread's priority, the doip threads just below it
	assert glue.contains('g_doip.entity_addr = u16(0x7b0)')
	assert glue.contains('g_doip.vin[0] = u8(0x42)') && glue.contains('g_doip.vin[16] = u8(0x58)')
	assert !glue.contains("'BLOBLYH735THREADX'"), 'a string in the generated runtime'
	assert glue.contains('g_doip.serve.answer = doipnet.answer')
	// below every application thread: the fixture's lowest is ctrl_slow at 13
	assert glue.contains("C.doip_net_create(c'192.168.0.50', u32(14), u32(15))")
	assert !glue.contains('functional_addr'), 'the default functional address is comm/doip\'s'
	// a reset waits for the CAN controller, then for DoIP answers still in TCP's transmit queue
	can_wait := glue.index('diag.wire_drain(mut ch') or { -1 }
	tcp_wait := glue.index('doipnet.drain_tx(diag_now_us)') or { -1 }
	reset := glue.index('\t\t\tC.diag_sys_reset()') or { -1 } // the call, not its declaration
	assert can_wait >= 0 && can_wait < tcp_wait && tcp_wait < reset
	// 0x27 (the 0x11 gate) declares the TRNG seam, which the TCP seed shares
	assert glue.contains('fn C.diag_sa_seed(&u8, int) int')
	// trace: the three threads bound in manifest order
	assert glue.contains('C.trace_bind_thread(C.doip_net_tcb(0)) // NetX IP thread')
	assert glue.contains('C.trace_bind_thread(C.doip_net_tcb(2)) // doip-svc')
}

// the ISO 13400-2 transport policy left out: comm/doip's defaults — any tester address, activation
// type 0x00 only (no list is generated), 2 s / 5 min inactivity, 3 announcements 500 ms apart —
// and the UDP side answers with the TCP socket count for entity status
fn test_an_unconfigured_policy_takes_the_iso_defaults() {
	code, out, glue := generate('doip_defaults', doip_conn)
	assert code == 0, out
	assert glue.contains('C.doip_net_timers(u32(2000), u32(300000))'), glue
	assert glue.contains('doipnet.run(mut g_doip, 3, 500, &g_doip_in[0], &g_doip_out[0])')
	assert !glue.contains('g_doip.n_testers') && !glue.contains('g_doip.n_act_types')
	assert glue.contains("@[export: 'blobly_doip_udp']")
	assert glue.contains('return doipnet.udp(&g_doip, req, n, resp)')
	// the timers are set before the threads that read them exist
	t := glue.index('C.doip_net_timers(') or { -1 }
	c := glue.index("C.doip_net_create(c'") or { -1 }
	assert t >= 0 && t < c
}

fn test_a_configured_policy_is_generated_into_the_entity() {
	code, out, glue := generate('doip_policy', doip_conn + 'testers = [0x0E80, 0x0F00]\n' +
		'activation_types = [0x00, 0xE1]\ninitial_inactivity_ms = 1000\ngeneral_inactivity_ms = 60000\n' +
		'announce_count = 5\nannounce_interval_ms = 200\n')
	assert code == 0, out
	for want in ['g_doip.testers[0] = u16(0xe80)', 'g_doip.testers[1] = u16(0xf00)',
		'g_doip.n_testers = 2', 'g_doip.act_types[0] = u8(0x0)', 'g_doip.act_types[1] = u8(0xe1)',
		'g_doip.n_act_types = 2', 'C.doip_net_timers(u32(1000), u32(60000))',
		'doipnet.run(mut g_doip, 5, 200, &g_doip_in[0], &g_doip_out[0])'] {
		assert glue.contains(want), want
	}
	// no announcements: discovery by identification request only
	c0, o0, g0 := generate('doip_quiet', doip_conn + 'announce_count = 0\n')
	assert c0 == 0, o0
	assert g0.contains('doipnet.run(mut g_doip, 0, 500, &g_doip_in[0], &g_doip_out[0])'), g0
}

fn test_a_policy_the_entity_cannot_serve_is_refused() {
	nine := '[' + []string{len: 9, init: '0x${(0x0E00 + index).hex()}'}.join(', ') + ']'
	cases := {
		'not_tester':   'testers = [0x0E00, 0x0001]\n'
		'tester_twice': 'testers = [0x0E00, 0x0E00]\n'
		'nine_testers': 'testers = ${nine}\n'
		'no_types':     'activation_types = []\n'
		'central_sec':  'activation_types = [0xE0]\n'
		'reserved':     'activation_types = [0x02]\n'
		'type_twice':   'activation_types = [0x00, 0x00]\n'
		'initial_low':  'initial_inactivity_ms = 50\n'
		'general_high': 'general_inactivity_ms = 3600001\n'
		'initial_long': 'initial_inactivity_ms = 20000\ngeneral_inactivity_ms = 10000\n'
		'ann_many':     'announce_count = 11\n'
		'ann_fast':     'announce_interval_ms = 5\n'
		'ann_long':     'announce_count = 4\nannounce_interval_ms = 3000\n' // 12 s before the first tester
		'no_testers':   'testers = []\n' // would read as "any"
		'float_timer':  'general_inactivity_ms = 60000.5\n'
		'wide_tester':  'testers = [0x100000E00]\n' // narrowed to 32 bits it would be 0x0E00
	}
	for name, extra in cases {
		code, out, _ := generate('doip_pol_${name}', doip_conn + extra)
		assert code != 0, 'loom2v accepted [doip] policy case ${name}'
		assert out.contains('[doip]'), '${name}: ${out}'
	}
}

fn test_a_doip_config_that_cannot_be_served_is_refused() {
	cases := {
		'no_server':  doip_conn.all_after('ascii = "BLOBLYH735THREADX"\n')
		'tester_la':  doip_conn.replace('logical_address = 0x07B0', 'logical_address = 0x0E80')
		'bad_ip':     doip_conn.replace('"192.168.0.50"', '"192.168.0"')
		'short_vin':  doip_conn.replace('BLOBLYH735THREADX', 'BLOBLYH735THREAD')
		'func_range': doip_conn + 'functional_address = 0x1234\n'
		// REQ-NET-012: a write reachable over IP needs a security level
		'open_write': doip_conn.replace('[doip]', '[[did]]\nid    = 0x0102\nbytes = "00"\nwrite = { session = ["extended"] }\n\n[doip]')
		// ...and so does any other change of ECU state: a reset gated by session alone,
		'open_reset': doip_open_reset
		// or the default table, which serves 0x11 to anyone
		'no_table':   doip_conn.all_after(doip_uds)
	}
	for name, extra in cases {
		code, out, _ := generate('doip_${name}', extra)
		assert code != 0, 'loom2v accepted [doip] case ${name}'
		assert out.contains('[doip]'), '${name}: ${out}'
	}
	// gated, the same write is accepted
	gated := doip_conn.replace('[doip]', '[[did]]\nid    = 0x0102\nbytes = "00"\nwrite = { session = ["extended"], security = 1 }\n\n[doip]')
	code, out, _ := generate('doip_gated', gated)
	assert code == 0, out
	// a table that leaves the reset out serves nothing that changes state: nothing to gate
	no_reset := doip_conn.replace('"0x11" = { sessions = ["extended"], security = 1 }\n', '').replace('"0x27" = {}\n',
		'')
	c2, o2, _ := generate('doip_no_reset', no_reset)
	assert c2 == 0, o2
}

// the gate on a state-changing service is the network tester's 0x27 level, wired into the table
fn test_a_doip_nodes_reset_is_gated_in_its_service_table() {
	code, out, glue := generate('doip_reset_gate', doip_conn)
	assert code == 0, out
	assert glue.contains('uds.Service{sid: 0x11, sessions: 0x04, security: 1}'), glue
	c2, o2, _ := generate('doip_open_reset', doip_open_reset)
	assert c2 != 0 && o2.contains('[uds] services 0x11 changes ECU state but needs no security level'), o2
	c3, o3, _ := generate('doip_no_table', doip_conn.all_after(doip_uds))
	assert c3 != 0 && o3.contains('has no [uds] services table'), o3
}

// a gated 0x2E row gates every write behind it (comm/uds checks the row before the DID), so a
// writable DID needs no level of its own there
fn test_a_gated_write_service_gates_its_dids() {
	row := '"0x2E" = { sessions = ["extended"], security = 1 }'
	did := '[[did]]\nid    = 0x0102\nbytes = "00"\nwrite = { session = ["extended"] }\n\n[doip]'
	code, out, glue := generate('doip_2e_row', doip_conn.replace('"0x2E" = {}', row).replace('[doip]',
		did))
	assert code == 0, out
	assert glue.contains('uds.Service{sid: 0x2e, sessions: 0x04, security: 1}'), glue
}

// blobly_net's reference key is public: over the network only by name (allow_bench_key), and the
// name means nothing without the key
fn test_the_public_bench_key_over_ip_is_allowed_only_by_name() {
	keyed := '\n[uds]\nsecurity_key = "reference"\n' + doip_conn
	code, out, _ := generate('doip_bench_key', keyed)
	assert code != 0 && out.contains('PUBLIC bench key'), out
	c2, o2, _ := generate('doip_bench_ok', keyed + 'allow_bench_key = true\n')
	assert c2 == 0, o2
	c3, o3, _ := generate('doip_bench_none', doip_conn + 'allow_bench_key = true\n')
	assert c3 != 0 && o3.contains('it would mean nothing'), o3
	c4, o4, _ := generate('doip_bench_bad', keyed + 'allow_bench_key = "yes"\n')
	assert c4 != 0 && o4.contains('must be true or false'), o4
}

// the [doip] address is a host of its subnet (tools/netcfg): on the default /24 not .0, .1 or .255
// (driver/eth/netx_up.c's network, broadcast and gateway addresses), on a configured one its own
fn test_the_doip_address_is_a_host_of_its_subnet() {
	for bad in ['192.168.0', '192.168..50', '1.2.3.0050', '192.168.0.0', '192.168.0.1', '192.168.0.255'] {
		code, out, _ := generate('doip_addr', doip_conn.replace('"192.168.0.50"', '"${bad}"'))
		assert code != 0 && out.contains('[doip] address "${bad}" is not'), '${bad}: ${out}'
	}
	code, out, _ := generate('doip_addr_16', doip_conn.replace('"192.168.0.50"', '"192.168.0.255"') +
		'netmask = "255.255.0.0"\n')
	assert code == 0, out
}

// the node's subnet: absent, nothing reaches the compiler and driver/eth's /24 with its .1 gateway
// stands (so the image is the one it was before the keys existed); configured, the values reach the
// application's network sources and LOOM_NET_ADDR_DEFS, which boot/boot.mk adds to the bootloader's
fn test_the_subnet_reaches_the_network_sources() {
	code, out, _, mk := generate_mk('net_default', doip_conn)
	assert code == 0, out
	assert mk.contains('LOOM_NET_ADDR_DEFS :=\nLOOM_NET_DEFS := -DBLOB_NET_POOL_COUNT=12u\n'), mk
	c2, o2, _, mk2 := generate_mk('net_set', doip_conn +
		'netmask = "255.255.254.0"\ngateway = "192.168.1.254"\n')
	assert c2 == 0, o2
	defs := '-DBLOB_NET_NETMASK=0xFFFFFE00UL -DBLOB_NET_GATEWAY=0xC0A801FEUL'
	assert mk2.contains('LOOM_NET_ADDR_DEFS := ${defs}\nLOOM_NET_DEFS := -DBLOB_NET_POOL_COUNT=12u ${defs}\n'), mk2
	// what the C does with them, and without them: today's constants
	src := os.read_file(os.join_path(@VMODROOT, 'driver', 'eth', 'netx_up.c')) or { panic(err) }
	for want in ['#ifndef BLOB_NET_NETMASK\n#define BLOB_NET_NETMASK 0xFFFFFF00UL\n#endif',
		'nx_ip_create(&ip, "net-ip", a, BLOB_NET_NETMASK,',
		'#ifdef BLOB_NET_GATEWAY\n\tnx_ip_gateway_address_set(&ip, BLOB_NET_GATEWAY);\n#else\n\tnx_ip_gateway_address_set(&ip, (a & BLOB_NET_NETMASK) | 1u);\n#endif'] {
		assert src.contains(want), want
	}
	// and the DoIP announcements go to that subnet's broadcast address
	doip := os.read_file(os.join_path(@VMODROOT, 'driver', 'eth', 'doip_netx.c')) or { panic(err) }
	for want in ['#ifdef BLOB_NET_NETMASK\n#define NET_BROADCAST(a) (((a) & BLOB_NET_NETMASK) | ~BLOB_NET_NETMASK)\n#else\n#define NET_BROADCAST(a) ((a) | 0xFFu)\n#endif',
		'nx_udp_socket_send(&udp_sock, p, NET_BROADCAST(blob_net_addr()), DOIP_PORT)'] {
		assert doip.contains(want), want
	}
}

// a subnet the target cannot bring up is refused, by tools/netcfg's rule (syscheck's)
fn test_a_subnet_the_node_cannot_bring_up_is_refused() {
	for keys, want in {
		'netmask = "255.0.255.0"':   'not a contiguous mask'
		'netmask = "/24"':           'netmask "/24" is not a dotted IPv4 address'
		'gateway = "192.168.1.1"':   'gateway "192.168.1.1" is not on the subnet 192.168.0.0/255.255.255.0'
		'gateway = "192.168.0.0"':   'is the network address of'
		'gateway = "192.168.0.255"': 'is the broadcast address of'
		'gateway = "192.168.0.50"':  'is its own gateway'
	} {
		code, out, _ := generate('net_bad', doip_conn + keys + '\n')
		assert code != 0 && out.contains(want), '${keys}: ${out}'
	}
}


// the trace recorder binds 8 thread ids: the fixture with DoIP fills them exactly (comm, three
// app threads, NetX IP, doip, doip-svc, the timer); one thread more is refused, not mislabelled
fn test_a_trace_past_the_recorders_thread_table_is_refused() {
	src := os.read_file(os.join_path(fixture_dir, 'ecu.toml')) or { panic(err) }
	at := src.index('  [[partition.thread]]') or { panic('no thread in the fixture') }
	more := src[..at] + '  [[partition.thread]]\n  name     = "extra"\n  priority = 14\n\n' + src[at..]
	code, out, _, _ := generate_ecu('doip_trace_full', more + doip_conn)
	assert code != 0, 'loom2v accepted 9 traced threads'
	assert out.contains('MAX_THREADS'), out	// and without the manifest argument too
	tmp := os.join_path(os.temp_dir(), 'doip_target_nomanifest_${os.getpid()}')
	defer {
		os.rmdir_all(tmp) or {}
	}
	os.mkdir_all(tmp) or { panic(err) }
	os.write_file(os.join_path(tmp, 'ecu.toml'), more + doip_conn) or { panic(err) }
	os.cp(os.join_path(fixture_dir, 'bus.dbc'), os.join_path(tmp, 'bus.dbc')) or {
		panic(err)
	}
	r := os.execute('${doip_loom2v()} ${os.join_path(tmp, 'ecu.toml')} ${os.join_path(tmp, 'bus.dbc')} ' +
		'${os.join_path(tmp, 'sig.v')} ${os.join_path(tmp, 'ports.v')} ${os.join_path(tmp, 'gen.v')}')
	assert r.exit_code != 0 && r.output.contains('MAX_THREADS'), r.output
}

// a writable VIN DID would let the announcement and 0x22 disagree after a write
fn test_a_writable_vin_is_refused() {
	gated := doip_conn.replace('ascii = "BLOBLYH735THREADX"', 'ascii = "BLOBLYH735THREADX"\nwrite = { session = ["extended"], security = 1 }')
	code, out, _ := generate('doip_vin_rw', gated)
	assert code != 0 && out.contains('cannot be writable'), out
}

// SOME/IP on an eth bus beside it: ONE NetX (driver/eth/netx_up.c) at ONE address, both seams
// linked through gen/loom_build.mk. Its own config: a CAN bus for the comm thread and the server,
// one cyclic SOME/IP frame on the eth bus, no [trace] (eth on a traced target is its own rung)
const doip_eth_ecu = '
[import]
dbc = "bus.dbc"

[target]
kind    = "threadx"
tick_ms = 1

[bus.can0]
interface = "vcan0"
fd        = false
core      = 0

[bus.eth0]
kind      = "eth"
interface = "192.168.0.50"
core      = 0

[someip]
bus     = "eth0"
service = 0x0100
version = 1
port    = 30490
peer    = "192.168.0.190:30491"

[[signal]]
name   = "EthLoad"
fields = { load = "u8" }
from   = "app"
to     = "eth0"

[[frame]]
name    = "EthTelem"
bus     = "eth0"
id      = 0x8001
signals = ["EthLoad"]
tx      = { mode = "cyclic", cycle_ms = 300 }

[[fb]]
name   = "Load"
thread = "idle"
  [[fb.handler]]
  name      = "on_100ms"
  period_ms = 100
  writes    = ["EthLoad"] # a trailing comment ends the nested table (vlang/v#27684)

[telemetry]
enabled   = true
bus       = "can0"
id        = 0x7E0
period_ms = 500
' + doip_conn + '
[[partition]]
name = "app"
core = 0

  [[partition.thread]]
  name = "idle"
'

fn test_doip_and_someip_share_one_netx() {
	code, out, glue, mk := generate_ecu('doip_eth', doip_eth_ecu)
	assert code == 0, out
	assert glue.contains("C.blob_eth_open(c'192.168.0.50', someip_port)")
	assert glue.contains("C.doip_net_create(c'192.168.0.50',")
	for src in ['driver/eth/netx_up.c', 'driver/eth/eth_netx.c', 'driver/eth/doip_netx.c',
		'boards/common/iocb.c'] {
		assert mk.contains(src), mk
	}
	// a node has one address
	c2, o2, _, _ := generate_ecu('doip_eth_addr', doip_eth_ecu.replace('address         = "192.168.0.50"',
		'address         = "192.168.0.60"'))
	assert c2 != 0 && o2.contains('a node has one address'), o2
	// and one UDP 13400: a SOME/IP endpoint there would take DoIP's socket
	c4, o4, _, _ := generate_ecu('doip_eth_port', doip_eth_ecu.replace('port    = 30490', 'port    = 13400'))
	assert c4 != 0 && o4.contains("is DoIP's"), o4
	// and one network: the subnet sits beside the address on both, and must be one subnet
	sub := doip_eth_ecu.replace('logical_address = 0x07B0\n', 'logical_address = 0x07B0\nnetmask = "255.255.0.0"\n')
	c5, o5, _, _ := generate_ecu('doip_eth_mask', sub)
	assert c5 != 0 && o5.contains('a node has one network'), o5
	both := sub.replace('interface = "192.168.0.50"\n', 'interface = "192.168.0.50"\nnetmask   = "255.255.0.0"\n')
	c6, o6, _, mk6 := generate_ecu('doip_eth_mask2', both)
	assert c6 == 0, o6
	assert mk6.contains('LOOM_NET_DEFS := -DBLOB_NET_POOL_COUNT=16u -DBLOB_NET_NETMASK=0xFFFF0000UL\n'), mk6
	// a CAN bus has no subnet
	c7, o7, _, _ := generate_ecu('doip_can_mask', both.replace('interface = "vcan0"\n', 'interface = "vcan0"\ngateway = "192.168.0.1"\n'))
	assert c7 != 0 && o7.contains('[bus.can0] `gateway` is an eth bus'), o7
	// and a node with neither links no network at all
	_, _, _, mk3 := generate_mk('no_net', '')
	assert mk3.contains('LOOM_NET_SRCS :=\n'), mk3
}
