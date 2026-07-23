module shell

// @verifies REQ-SHELL-001 REQ-SHELL-002 REQ-SHELL-003
import comm.isotp
import driver.can

// pump drives the module's produce against a host-side ISO-TP link (FC routed back to on_fc),
// returning the reassembled response text — the same wire round trip the GUI does.
fn pump(mut m ShellModule) string {
	mut host := isotp.Link{}
	mut now := u64(1000)
	mut f := can.Frame{}
	for _ in 0 .. 200 {
		if m.produce(now, mut f) {
			assert f.id == 0x7f1
			mut p := isotp.Pdu{}
			for j in 0 .. 8 {
				p.data[j] = f.data[j]
			}
			host.on_frame(now, p)
		}
		mut fc := isotp.Pdu{}
		if host.poll(now, mut fc) {
			mut fcf := can.Frame{
				id:  0x7f2
				len: 8
			}
			for j in 0 .. 8 {
				fcf.data[j] = fc.data[j]
			}
			m.on_fc(now, fcf)
		}
		now += 500
	}
	mut buf := [isotp.max_payload]u8{}
	n := host.take(&buf[0])
	if n <= 0 {
		return ''
	}
	mut out := ''
	for i in 0 .. n {
		out += u8(buf[i]).ascii_str()
	}
	return out
}

fn line(s string) can.Frame {
	mut f := can.Frame{
		id:  0x7f0
		len: u8(s.len)
	}
	for i in 0 .. s.len {
		f.data[i] = s[i]
	}
	return f
}

fn test_help_lists_commands() {
	mut m := ShellModule{}
	m.init(0x7f1)
	m.register('ps', 'threads + stacks', fn (args &u8, args_len int, now u64, mut rsp Rsp) {
		rsp.write('fake ps')
		rsp.nl()
	})
	m.on_in(0, line('help'))
	out := pump(mut m)
	assert out.contains('help')
	assert out.contains('uptime')
	assert out.contains('ps      - threads + stacks') // 8-col aligned name
}

fn test_dispatch_and_args() {
	mut m := ShellModule{}
	m.init(0x7f1)
	m.register('echo', 'echo args', fn (args &u8, args_len int, now u64, mut rsp Rsp) {
		for i in 0 .. args_len {
			b := unsafe { args[i] }
			if rsp.len < max_rsp {
				rsp.buf[rsp.len] = b
				rsp.len++
			}
		}
		rsp.nl()
	})
	m.on_in(0, line('echo hi'))
	assert pump(mut m) == 'hi\n'
}

fn test_uptime_and_unknown() {
	mut m := ShellModule{}
	m.init(0x7f1)
	m.on_in(u64(125_000_000), line('uptime'))
	out := pump(mut m)
	assert out.contains('up 2m 5s')
	m.on_in(0, line('nope'))
	out2 := pump(mut m)
	assert out2.contains('unknown command')
	assert out2.contains('"nope"')
}

fn test_busy_drops_second_line() {
	mut m := ShellModule{}
	m.init(0x7f1)
	m.on_in(0, line('help'))
	// response still streaming (nothing pumped yet): a second line is dropped, not interleaved
	m.on_in(0, line('uptime'))
	out := pump(mut m)
	assert out.contains('uptime  - time since boot') // the help listing (8-col aligned), not the uptime output
	assert !out.contains('up 0m')
}

// --- the access gate (REQ-NET-018 groundwork, deliberately left untagged for
// trace: the requirement verifies where a state-changing method is really
// exposed over the network; this proves the enforcement mechanism) ---------

fn poke_cmd(args &u8, args_len int, now u64, mut rsp Rsp) {
	rsp.write('poked')
	rsp.nl()
}

fn gline(s string) [64]u8 {
	mut d := [64]u8{}
	for i in 0 .. s.len {
		d[i] = s[i]
	}
	return d
}

fn test_dispatch_gates_mutating_commands() {
	mut m := ShellModule{}
	m.init(0)
	m.register_mut('poke', 'a state-changing test command', poke_cmd)
	// gated wire: the mutating command is refused BEFORE it runs
	mut rsp := Rsp{}
	assert !m.dispatch(gline('poke'), 4, 0, false, mut rsp)
	assert rsp.len == 0, 'the gate must refuse before the command writes anything'
	// ungated wire: it runs
	mut rsp2 := Rsp{}
	assert m.dispatch(gline('poke'), 4, 0, true, mut rsp2)
	assert rsp2.len > 0
	// read-class commands pass the gated wire untouched
	mut rsp3 := Rsp{}
	assert m.dispatch(gline('uptime'), 6, 0, false, mut rsp3)
	assert rsp3.len > 0
	// unknown command is a NORMAL response either way (the router's business
	// is method ids; unknown LINES answer with help text, never a refusal)
	mut rsp4 := Rsp{}
	assert m.dispatch(gline('nosuch'), 6, 0, false, mut rsp4)
	assert rsp4.len > 0
}
