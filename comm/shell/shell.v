module shell

import comm.com
import comm.isotp
import driver.can

// ShellModule — an interactive command line over CAN, as an ordinary ComModule
// (docs/com-modules.md): a command LINE arrives as one raw frame on `in` (≤ 8 chars — bmc, ps,
// help, top all fit; multi-frame input is a later slice), the handler runs BOUNDED on the comm
// thread, and the text response streams as one ISO-TP block on `out`, flow-controlled by the
// host on `fc` — the exact wire shape the trace dump proved. Line editing (backspace, history)
// is the CLIENT's job; the target only ever sees complete lines.
//
// How commands may interact with the rest of the system (the com-modules rules):
//   1. read-only hardware/kernel globals (DWT counters, the ThreadX thread list): direct reads;
//   2. comm-thread-owned modules (trace): direct calls — same thread, no locks;
//   3. other threads' data: read their PUBLISHED slots (single-writer scratch / IOC);
//   4. mutating another thread: a request via the mode mailbox / IOC — never a direct poke.
// A handler must be bounded and non-blocking: it runs inside the bus owner's loop.
pub const endpoints = [
	com.Endpoint{
		name: 'in'
		dir:  .rx
		dlc:  0 // a raw command line, 1..8 bytes (frame length = line length)
		doc:  'the command line (one raw frame)'
	},
	com.Endpoint{
		name: 'fc'
		dir:  .rx
		dlc:  8
		doc:  'ISO-TP flow control for the response stream'
	},
	com.Endpoint{
		name: 'out'
		dir:  .tx
		dlc:  8
		doc:  'the response text (one ISO-TP block)'
	},
]

pub const max_rsp = isotp.max_payload // one ISO-TP block; help/ps for a handful of threads fits

// Rsp is the no-alloc response writer — a fixed buffer the handlers append text into.
pub struct Rsp {
pub mut:
	buf [520]u8
	len int
}

pub fn (mut r Rsp) write(s string) {
	for i in 0 .. s.len {
		if r.len >= max_rsp {
			return
		}
		r.buf[r.len] = s[i]
		r.len++
	}
}

pub fn (mut r Rsp) write_u32(n u32) {
	if n == 0 {
		r.write('0')
		return
	}
	mut digits := [10]u8{}
	mut v := n
	mut nd := 0
	for v > 0 {
		digits[nd] = u8(`0` + v % 10)
		v /= 10
		nd++
	}
	for i := nd - 1; i >= 0; i-- {
		if r.len >= max_rsp {
			return
		}
		r.buf[r.len] = digits[i]
		r.len++
	}
}

// write_u32_padded writes n space-padded to column w (tabular output, like write_padded).
// The pad count is computed BEFORE the loop on purpose: a V range bound is re-evaluated
// every iteration (C for-loop semantics), so a bound depending on r.len — which each
// r.write(' ') advances — would chase itself and pad only half the distance.
pub fn (mut r Rsp) write_u32_padded(n u32, w int) {
	start := r.len
	r.write_u32(n)
	mut pad := w - (r.len - start)
	if pad < 1 {
		pad = 1
	}
	for _ in 0 .. pad {
		r.write(' ')
	}
}

pub fn (mut r Rsp) nl() {
	r.write('\n')
}

// write_padded writes s space-padded to column w (one space minimum when s overflows w),
// so tabular output (the help listing, ps) lines up.
pub fn (mut r Rsp) write_padded(s string, w int) {
	r.write(s)
	if s.len >= w {
		r.write(' ')
		return
	}
	for _ in 0 .. w - s.len {
		r.write(' ')
	}
}

// CmdFn runs one command: raw argument bytes (whatever followed the command name), the current
// time (µs, the bus owner's clock), and the response writer. BOUNDED — it runs on the comm thread.
pub type CmdFn = fn (args &u8, args_len int, now u64, mut rsp Rsp)

struct Cmd {
	name   string
	help   string
	f      CmdFn = unsafe { nil }
	mutate bool // state-changing: the eth RPC gate refuses it unless the build allows
}

pub struct ShellModule {
mut:
	out_id u32
	link   isotp.Link
	cmds   [16]Cmd
	ncmd   int
}

// init prepares the module IN PLACE — the instance usually lives in a __global (its ISO-TP
// link alone is ~1 KB), and building it as a stack local + return-copy would put ~2x its size
// on the caller's (4 KB comm) stack. No constructor by value, ever, for module-sized structs.
pub fn (mut m ShellModule) init(out_id u32) {
	m.out_id = out_id
	m.link.init_defaults() // _vinit never runs on target: timeouts are set HERE
	m.ncmd = 0
	// help is handled intrinsically in on_in (a plain fn pointer can't reach the registry);
	// everything else is an ordinary registered command.
	m.register('uptime', 'time since boot', uptime_cmd)
	// clear is really the CLIENT's job (the scrollback is the client's display, and the GUI
	// intercepts it locally) — registered here anyway so help, the registry's single source
	// of truth, lists it; a client that does forward it gets a truthful answer.
	m.register('clear', 'clear the screen (client-side)', clear_cmd)
}

// register adds a READ-class command (static name/help strings; the table is
// fixed-size, no alloc). Read commands observe state and never change it.
pub fn (mut m ShellModule) register(name string, help string, f CmdFn) {
	m.register_class(name, help, f, false)
}

// register_mut adds a STATE-CHANGING command. Over eth these sit behind the
// build-time access gate (REQ-NET-018): a build without the gate exposes only
// read-class methods. The CAN shell is not gated — its threat model is
// physical bus access, the net requirement's scope is the network path.
pub fn (mut m ShellModule) register_mut(name string, help string, f CmdFn) {
	m.register_class(name, help, f, true)
}

fn (mut m ShellModule) register_class(name string, help string, f CmdFn, mutate bool) {
	if m.ncmd >= m.cmds.len {
		return
	}
	m.cmds[m.ncmd] = Cmd{
		name:   name
		help:   help
		f:      f
		mutate: mutate
	}
	m.ncmd++
}

// on_in serves the `in` endpoint: one raw frame = one command line. Split "name args", find the
// command, run it, and hand the response to the ISO-TP link (produce streams it). While a previous
// response still streams, the line is answered with a busy note appended after it drains — keep it
// simple: drop with no reply (the client times out and the user retypes; single-flight by design).
pub fn (mut m ShellModule) on_in(now u64, f can.Frame) {
	if m.link.busy() || f.len == 0 {
		return
	}
	// split the line at the first space: [0..sp) = name, (sp..len) = args
	mut sp := int(f.len)
	for i in 0 .. int(f.len) {
		if f.data[i] == ` ` {
			sp = i
			break
		}
	}
	mut rsp := Rsp{}
	m.dispatch(f.data, int(f.len), now, true, mut rsp)
	m.link.send(&rsp.buf[0], rsp.len)
}

// dispatch runs one command LINE into rsp — the transport-free core both
// wires share: the CAN shell (on_in -> ISO-TP stream) and the eth RPC path
// (request payload -> one response datagram, docs/someip.md P3). allow_mutate
// is the access gate (REQ-NET-018): a state-changing command on a gated wire
// is REFUSED before it runs. Returns false exactly for that refusal, so the
// eth path answers with the rc_denied error response; every other outcome
// (incl. unknown command) is a normal response with rsp text.
pub fn (mut m ShellModule) dispatch(data [64]u8, len int, now u64, allow_mutate bool, mut rsp Rsp) bool {
	// split the line at the first space: [0..sp) = name, (sp..len) = args
	mut sp := len
	for i in 0 .. len {
		if data[i] == ` ` {
			sp = i
			break
		}
	}
	// `help` is intrinsic: it lists the registry, which a plain fn pointer can't reach.
	if sp == 4 && name_eq('help', data, 4) {
		rsp.write_padded('help', 8)
		rsp.write('- list commands')
		rsp.nl()
		for i in 0 .. m.ncmd {
			rsp.write_padded(m.cmds[i].name, 8)
			rsp.write('- ')
			rsp.write(m.cmds[i].help)
			rsp.nl()
		}
		return true
	}
	mut found := false
	for i in 0 .. m.ncmd {
		c := m.cmds[i]
		if c.name.len == sp && name_eq(c.name, data, sp) {
			if c.mutate && !allow_mutate {
				return false // the access gate: refused BEFORE it acts
			}
			ai := if sp < len { sp + 1 } else { len }
			c.f(unsafe { &data[ai] }, len - ai, now, mut rsp)
			found = true
			break
		}
	}
	if !found {
		rsp.write('unknown command — try help')
		rsp.nl()
		// echo what we got, so a mistyped/truncated line is diagnosable
		rsp.write('got: "')
		for i in 0 .. len {
			if rsp.len < max_rsp {
				rsp.buf[rsp.len] = data[i]
				rsp.len++
			}
		}
		rsp.write('"')
		rsp.nl()
	}
	if rsp.len == 0 {
		rsp.write('ok')
		rsp.nl()
	}
	return true
}

fn name_eq(name string, data [64]u8, n int) bool {
	for i in 0 .. n {
		if name[i] != data[i] {
			return false
		}
	}
	return true
}

// on_fc serves the `fc` endpoint: the host's ISO-TP flow control for the response stream.
pub fn (mut m ShellModule) on_fc(now u64, f can.Frame) {
	if f.len < 3 {
		return
	}
	mut p := isotp.Pdu{}
	for i in 0 .. 8 {
		p.data[i] = f.data[i]
	}
	m.link.on_frame(now, p)
}

// produce fills at most ONE tx frame per call (the bus owner gates on tx_ready) — the response
// stream, ISO-TP paced.
pub fn (mut m ShellModule) produce(now u64, mut f can.Frame) bool {
	m.link.tick(now)
	mut p := isotp.Pdu{}
	if m.link.poll(now, mut p) {
		f.id = m.out_id
		f.len = 8
		for i in 0 .. 8 {
			f.data[i] = p.data[i]
		}
		return true
	}
	return false
}

// builtins ---------------------------------------------------------------------------------------

fn clear_cmd(args &u8, args_len int, now u64, mut rsp Rsp) {
	rsp.write("(clearing is the client display's job)")
	rsp.nl()
}

fn uptime_cmd(args &u8, args_len int, now u64, mut rsp Rsp) {
	secs := u32(now / 1_000_000)
	rsp.write('up ')
	rsp.write_u32(secs / 60)
	rsp.write('m ')
	rsp.write_u32(secs % 60)
	rsp.write('s')
	rsp.nl()
}
