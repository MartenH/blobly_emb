// loom2v's SHELL codegen — thin wiring for comm/shell's ShellModule (docs/com-modules.md):
// parse the [shell] endpoint bindings, emit the router arms + produce drain into the comm
// thread, register the target-backed commands (ps — the ThreadX thread list lives in C), and
// advertise the frame ids in the manifest. The protocol lives in the platform; this file only
// binds it to the wire, exactly like gen_trace.v.
module main

import toml
import comm.shell

const shell_config_keys = ['enabled', 'bus', 'commands', 'method', 'allow_mutate']

struct ShellCfg {
mut:
	on     bool
	bus    string
	in_id  u32 = 0x7F0
	fc_id  u32 = 0x7F2
	out_id u32 = 0x7F1
	// the eth RPC form (docs/someip.md P3): the command line rides ONE method
	// id; the access gate defaults CLOSED (REQ-NET-018)
	method       u32
	allow_mutate bool
	// example-provided commands ([shell] commands = ["cm4"]): each name X becomes
	// `int shell_X(unsigned char*, int)` in the example's comm_glue.c, an adapter, and a
	// registry entry — target-backed commands without touching the generator per command.
	commands []string
}

fn parse_shell(doc toml.Doc, dbc string) ShellCfg {
	mut t := ShellCfg{}
	if scfg := doc.value_opt('shell') {
		sm := scfg.as_map()
		t.on = (sm['enabled'] or { toml.Any(true) }).bool()
		t.bus = (sm['bus'] or { toml.Any('') }).string()
		if t.bus == '' {
			// the validator's inherit rule, mirrored: [shell] without a bus
			// rides [telemetry].bus — resolving it HERE keeps shell_on_eth
			// true for an inherited eth binding (silent no-emit otherwise)
			if tv := doc.value_opt('telemetry') {
				t.bus = (tv.as_map()['bus'] or { toml.Any('') }).string()
			}
		}
		t.method = u32((sm['method'] or { toml.Any(0) }).int())
		t.allow_mutate = (sm['allow_mutate'] or { toml.Any(false) }).bool()
		for c in (sm['commands'] or { toml.Any([]toml.Any{}) }).array() {
			name := c.string()
			if name.len == 0 || name.len > 8 {
				panic('loom2v: [shell] commands: "${name}" must be 1..8 chars (one CAN frame)')
			}
			for ch in name {
				if !((ch >= `a` && ch <= `z`) || (ch >= `0` && ch <= `9`) || ch == `_`) {
					panic('loom2v: [shell] commands: "${name}" must be [a-z0-9_] (a C symbol suffix)')
				}
			}
			t.commands << name
		}
		mut endpoint_names := []string{}
		for e in shell.endpoints {
			endpoint_names << e.name
		}
		for k, _ in sm {
			if k !in shell_config_keys && k !in endpoint_names {
				panic('loom2v: [shell] unknown key "${k}" — endpoints: ${endpoint_names}, ' +
					'config: ${shell_config_keys}')
			}
		}
		if t.on {
			for e in shell.endpoints {
				match e.name {
					'in' { t.in_id = trace_binding(sm, e.name, e.dlc, t.in_id, dbc) }
					'fc' { t.fc_id = trace_binding(sm, e.name, e.dlc, t.fc_id, dbc) }
					'out' { t.out_id = trace_binding(sm, e.name, e.dlc, t.out_id, dbc) }
					else { panic('loom2v: comm.shell endpoint "${e.name}" has no ShellCfg field — teach parse_shell about it') }
				}
			}
		}
	}
	return t
}

// shell_c_decls: the target-backed command externs (ps walks the ThreadX created-thread list).
fn shell_c_decls(m Model) []string {
	if !m.shell.on {
		return []string{}
	}
	mut g := [
		'fn C.shell_ps(&u8, int) int',
		'fn C.shell_bmc(&u8, int) int',
	]
	for name in m.shell.commands {
		g << 'fn C.shell_${name}(&u8, int) int'
	}
	return g
}

// shell_module_globals / init: the module lives in __global (its ISO-TP link is ~1 KB).
fn shell_module_globals(m Model) []string {
	if !m.shell.on {
		return []string{}
	}
	return ['\tg_sh shell.ShellModule']
}

fn shell_module_init(m Model) []string {
	if !m.shell.on {
		return []string{}
	}
	base := [
		'\tg_sh.init(u32(0x${m.shell.out_id.hex()})) // in place: no module-sized stack copies',
		"\tg_sh.register('ps', 'threads: prio, state, stack high-water', shell_ps_cmd)",
		"\tg_sh.register('bmc', 'DWT core benchmark (CPI, LSU, folds)', shell_bmc_cmd)",
		'\tmut shell_txf := can.Frame{}',
	]
	mut g := base.clone()
	for name in m.shell.commands {
		g.insert(g.len - 1, "\tg_sh.register('${name}', 'target command (comm_glue.c)', shell_${name}_cmd)")
	}
	return g
}

// shell_cmd_fns: module-level command adapters (target-backed commands bridge to C here — the
// platform module stays pure V and host-testable).
fn shell_cmd_fns(m Model) []string {
	if !m.shell.on {
		return []string{}
	}
	base := [
		'',
		'fn shell_ps_cmd(args &u8, args_len int, now u64, mut rsp shell.Rsp) {',
		'\tn := C.shell_ps(&rsp.buf[0], ${shell.max_rsp})',
		'\tif n > 0 {',
		'\t\trsp.len = n',
		'\t}',
		'}',
		'',
		'fn shell_bmc_cmd(args &u8, args_len int, now u64, mut rsp shell.Rsp) {',
		'\tn := C.shell_bmc(&rsp.buf[0], ${shell.max_rsp})',
		'\tif n > 0 {',
		'\t\trsp.len = n',
		'\t}',
		'}',
	]
	mut g := base.clone()
	for name in m.shell.commands {
		g << ''
		g << 'fn shell_${name}_cmd(args &u8, args_len int, now u64, mut rsp shell.Rsp) {'
		g << '\tn := C.shell_${name}(&rsp.buf[0], ${shell.max_rsp})'
		g << '\tif n > 0 {'
		g << '\t\trsp.len = n'
		g << '\t}'
		g << '}'
	}
	return g
}

// shell_rx_arms: the router match arms in the comm thread's rx drain.
fn shell_rx_arms(m Model) []string {
	if !m.shell.on {
		return []string{}
	}
	mut g := []string{}
	g << '\t\t\tif rx.id == u32(0x${m.shell.in_id.hex()}) { // shell.in -> one command line'
	g << '\t\t\t\tg_sh.on_in(C.board_now_us(), rx)'
	g << '\t\t\t}'
	g << '\t\t\tif rx.id == u32(0x${m.shell.fc_id.hex()}) { // shell.fc -> ISO-TP FC'
	g << '\t\t\t\tg_sh.on_fc(C.board_now_us(), rx)'
	g << '\t\t\t}'
	return g
}

fn shell_produce_drain(m Model) []string {
	if !m.shell.on {
		return []string{}
	}
	return [
		// REQ-COM-007: silent in sleep — the response stays queued in the module
		// and goes out after wake (the link does not tick while gated).
		'\t\tfor ${nm_gate(m)}ch.tx_ready() && g_sh.produce(t1, mut shell_txf) {',
		'\t\t\tch.send(shell_txf)',
		'\t\t}',
	]
}

fn shell_manifest_frames(m Model) []string {
	if !m.shell.on {
		return []string{}
	}
	if shell_on_eth(m) {
		// the RPC form: ONE method id — the CAN in/fc/out endpoints do not
		// exist on this image, so the manifest must not invent them
		return [
			'# eth modules: module,endpoint,id',
			'ethmod,shell,method,0x${m.shell.method.hex()}',
		]
	}
	sbus := if m.shell.bus != '' { m.shell.bus } else { m.telem.bus }
	return [
		'# shell frames: frame,id,bus',
		'in,0x${m.shell.in_id.hex()},${sbus}',
		'fc,0x${m.shell.fc_id.hex()},${sbus}',
		'out,0x${m.shell.out_id.hex()},${sbus}',
	]
}

// shell_on_eth: the [shell] module is bound to the eth bus — the RPC form
// (docs/someip.md P3): one method id, request -> dispatch -> response
// datagram, served by the generated eth thread.
fn shell_on_eth(m Model) bool {
	return m.shell.on && m.eth != '' && m.shell.bus == m.eth
}

// shell_eth_init: the eth thread's registry init. Built-ins + the configured
// C-backed commands only — the CAN-side ps/bmc registrations stay with the
// comm-thread glue that provides their C halves; sharing that C is its own
// cleanup rung.
fn shell_eth_init(m Model) []string {
	if !shell_on_eth(m) {
		return []string{}
	}
	mut g := ['\tg_sh.init(u32(0)) // in place; out_id unused on eth (responses are datagrams)']
	// the generated read-only stat command (per-handler timing) serves eth too
	g << "\tg_sh.register('stat', 'per-handler us: last, max, mean, count', shell_stat_cmd)"
	for name in m.shell.commands {
		// C-backed commands are OPAQUE to the generator — fail CLOSED: they
		// register as state-changing, so the REQ-NET-018 gate covers them
		// unless the build opens it (a per-command declared class is a later
		// schema rung)
		g << "\tg_sh.register_mut('${name}', 'target command (glue)', shell_${name}_cmd)"
	}
	return g
}

// eth_thread_on: the generated eth thread exists for eth FRAMES or an
// eth-bound shell (an RPC-only image has no [[frame]] yet still serves its
// method) — every emission site keys on this, not on the frame count.
fn eth_thread_on(m Model) bool {
	return m.target.threadx && (m.eth_frames.len > 0 || shell_on_eth(m))
}
