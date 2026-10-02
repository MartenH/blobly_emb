module main

import comm.e2e
import comm.someip
import net
import os
import time

// An eth [[frame]]'s own `peer` (rung 6: a segment of more than two members). A member that
// exchanges different events with different members sends each tx event to, and accepts each rx
// event only FROM, that event's peer — [someip].peer stays the default for the rest. The static
// filter is still static (REQ-NET-017): it now has one legal talker per EVENT rather than one per
// node, and a known talker must not be able to inject another member's event.
//
// Proven on the wire: examples/host_someip generated with BenchCmd moved to a second peer, built
// and run on loopback, then probed from the default peer, the event's peer and a stranger.
// @verifies REQ-NET-017

// four consecutive ports per process, so a parallel run (or host_someip's own e2e test on
// 30490/30491) never shares one
const fp_base = 20000 + (os.getpid() % 2000) * 4 // below the ephemeral range
const fp_app_port = fp_base
const fp_default_port = fp_base + 1 // [someip].peer — every event but BenchCmd
const fp_cmd_port = fp_base + 2 // BenchCmd's own peer
const fp_rogue_port = fp_base + 3
const fp_service = u16(0x0100)
const fp_id_echo = u16(0x8004)
const fp_id_cmd = u16(0x8010)
const fp_id_cmd_safe = u16(0x8011)

// frame_peer_example generates + builds examples/host_someip with BenchCmd on its own peer, in a
// scratch dir; returns the scratch dir (bin at <dir>/app) and the generated glue.
fn frame_peer_example() (string, string) {
	repo := @VMODROOT
	ex := os.join_path(repo, 'examples', 'host_someip')
	tmp := os.join_path(os.temp_dir(), 'eth_frame_peer_${os.getpid()}_${time.now().unix_nano()}')
	for sub in ['gen', 'ports', 'sig', 'app'] {
		os.mkdir_all(os.join_path(tmp, sub)) or { panic(err) }
	}
	os.cp(os.join_path(ex, 'main.v'), os.join_path(tmp, 'main.v')) or { panic(err) }
	os.cp(os.join_path(ex, 'app', 'bench.v'), os.join_path(tmp, 'app', 'bench.v')) or { panic(err) }
	mut cfg := os.read_file(os.join_path(ex, 'ecu.toml')) or { panic(err) }
	cfg = cfg.replace('port    = 30490\npeer    = "127.0.0.1:30491"', 'port    = ${fp_app_port}\npeer    = "127.0.0.1:${fp_default_port}"')
	cfg = cfg.replace('name    = "BenchCmd"\nbus     = "eth0"\nid      = 0x8010', 'name    = "BenchCmd"\nbus     = "eth0"\nid      = 0x8010\npeer    = "127.0.0.1:${fp_cmd_port}"')
	assert cfg.contains('peer    = "127.0.0.1:${fp_cmd_port}"'), 'host_someip changed shape: BenchCmd not found'
	assert cfg.contains('port    = ${fp_app_port}'), 'host_someip changed shape: [someip] not found'
	ecu := os.join_path(tmp, 'ecu.toml')
	os.write_file(ecu, cfg) or { panic(err) }
	vexe := os.quoted_path(@VEXE)
	glue := os.join_path(tmp, 'gen', 'loom_gen.v')
	for cmd in [
		'${vexe} -enable-globals run ${os.join_path(repo, 'tools', 'ecucheck', 'gen.v')} ${ecu}',
		'${vexe} -enable-globals run ${os.join_path(repo, 'tools', 'cfg2v', 'gen.v')} ${ecu} ${os.join_path(tmp,
			'gen', 'ecu_gen.v')}',
		'${vexe} -enable-globals run ${os.join_path(repo, 'tools', 'loom2v')} ${ecu} ${os.join_path(tmp,
			'bus.dbc')} ${os.join_path(tmp, 'sig', 'signals_gen.v')} ${os.join_path(tmp, 'ports',
			'ports_gen.v')} ${glue} ${os.join_path(tmp, 'gen', 'manifest.csv')}',
	] {
		r := os.execute(cmd)
		assert r.exit_code == 0, '${cmd}\n${r.output}'
	}
	r := os.execute('cd ${os.quoted_path(repo)} && ${vexe} -gc none -enable-globals -path "@vlib|@vmodules|.|${tmp}" -o ${os.join_path(tmp,
		'app_bin')} ${tmp}')
	assert r.exit_code == 0, r.output
	return tmp, os.read_file(glue) or { '' }
}

fn fp_cmd(level u8) []u8 {
	h := someip.notification(fp_service, fp_id_cmd, 1, 1)
	mut d := []u8{len: someip.header_len + 1}
	someip.encode(h, unsafe { &d[0] })
	d[someip.header_len] = level
	return d
}

fn fp_cmd_safe(mut tx e2e.TxState, level u8) []u8 {
	h := someip.notification(fp_service, fp_id_cmd_safe, 1, 3)
	mut d := []u8{len: someip.header_len + 3}
	someip.encode(h, unsafe { &d[0] })
	d[someip.header_len] = level
	tx.protect(unsafe { &d[someip.header_len] }, 3, 0x22, 2, 1)
	return d
}

// fp_echoes: every BenchEcho level arriving at the default peer within the window
fn fp_echoes(mut c net.UdpConn, window time.Duration) []u8 {
	mut out := []u8{}
	mut buf := []u8{len: 2048}
	start := time.now()
	for time.since(start) < window {
		n, _ := c.read(mut buf) or { continue }
		if n < someip.header_len + 1 {
			continue
		}
		h, ok := someip.decode(unsafe { &buf[0] }, n)
		if ok && h.method == fp_id_echo {
			out << buf[someip.header_len]
		}
	}
	return out
}

fn test_an_event_is_accepted_only_from_its_own_peer() {
	dir, glue := frame_peer_example()
	defer {
		os.rmdir_all(dir) or {}
	}
	// the shape: BenchCmd's own consts, a filter admitting both talkers, a per-event check
	assert glue.contains('pub const bench_cmd_peer_port = u16(${fp_cmd_port})'), glue
	assert glue.contains('eth_src_is(rx_ip, rx_port, bench_cmd_peer_ip, bench_cmd_peer_port)'), glue

	mut def := net.listen_udp('127.0.0.1:${fp_default_port}')!
	def.set_read_timeout(100 * time.millisecond)
	defer {
		def.close() or {}
	}
	mut cmdp := net.listen_udp('127.0.0.1:${fp_cmd_port}')!
	defer {
		cmdp.close() or {}
	}
	mut rogue := net.listen_udp('127.0.0.1:${fp_rogue_port}')!
	defer {
		rogue.close() or {}
	}
	app := net.resolve_addrs('127.0.0.1:${fp_app_port}', .ip, .udp)![0]
	mut p := os.new_process(os.join_path(dir, 'app_bin'))
	p.set_redirect_stdio()
	p.run()
	defer {
		p.signal_kill()
		p.wait()
	}
	// BenchCmd from ITS peer is accepted (and echoed to the default peer). Resent until the
	// echo shows, so a slow start-up (the app not bound yet) is waited out, not failed.
	mut echoes := []u8{}
	for _ in 0 .. 20 {
		cmdp.write_to(app, fp_cmd(42))!
		echoes = fp_echoes(mut def, 500 * time.millisecond)
		if 42 in echoes {
			break
		}
	}
	assert 42 in echoes, 'BenchCmd from its own peer was not accepted'
	// ...from the DEFAULT peer it is not: a known talker, but not this event's producer
	def.write_to(app, fp_cmd(77))!
	// ...nor from a stranger
	rogue.write_to(app, fp_cmd(78))!
	echoes = fp_echoes(mut def, 1000 * time.millisecond)
	assert 77 !in echoes, 'BenchCmd accepted from the default peer — a known talker injected another member\'s event'
	assert 78 !in echoes, 'BenchCmd accepted from a stranger'

	// BenchCmdSafe has no peer of its own: the default peer's alone (echo = 42 + safe level)
	mut prot := e2e.TxState{}
	cmdp.write_to(app, fp_cmd_safe(mut prot, 100))!
	echoes = fp_echoes(mut def, 1000 * time.millisecond)
	assert 142 !in echoes, 'BenchCmdSafe accepted from BenchCmd\'s peer'
	mut prot2 := e2e.TxState{}
	def.write_to(app, fp_cmd_safe(mut prot2, 50))!
	echoes = fp_echoes(mut def, 2000 * time.millisecond)
	assert 92 in echoes, 'BenchCmdSafe from the default peer was not accepted'
}
