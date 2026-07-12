// loom2v's SHELL codegen — thin wiring for comm/shell's ShellModule (docs/com-modules.md):
// parse the [shell] endpoint bindings, emit the router arms + produce drain into the comm
// thread, register the target-backed commands (ps — the ThreadX thread list lives in C), and
// advertise the frame ids in the manifest. The protocol lives in the platform; this file only
// binds it to the wire, exactly like gen_trace.v.
module main

import toml
import comm.shell

const shell_config_keys = ['enabled', 'bus']

struct ShellCfg {
mut:
	on     bool
	bus    string
	in_id  u32 = 0x7F0
	fc_id  u32 = 0x7F2
	out_id u32 = 0x7F1
}

fn parse_shell(doc toml.Doc, dbc string) ShellCfg {
	mut t := ShellCfg{}
	if scfg := doc.value_opt('shell') {
		sm := scfg.as_map()
		t.on = (sm['enabled'] or { toml.Any(true) }).bool()
		t.bus = (sm['bus'] or { toml.Any('') }).string()
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
	return ['fn C.shell_ps(&u8, int) int']
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
	return [
		'\tg_sh.init(u32(0x${m.shell.out_id.hex()})) // in place: no module-sized stack copies',
		"\tg_sh.register('ps', 'threads: prio, state, stack high-water', shell_ps_cmd)",
		'\tmut shell_txf := can.Frame{}',
	]
}

// shell_cmd_fns: module-level command adapters (target-backed commands bridge to C here — the
// platform module stays pure V and host-testable).
fn shell_cmd_fns(m Model) []string {
	if !m.shell.on {
		return []string{}
	}
	return [
		'',
		'fn shell_ps_cmd(args &u8, args_len int, now u64, mut rsp shell.Rsp) {',
		'\tn := C.shell_ps(&rsp.buf[0], ${shell.max_rsp})',
		'\tif n > 0 {',
		'\t\trsp.len = n',
		'\t}',
		'}',
	]
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
		'\t\tfor ch.tx_ready() && g_sh.produce(t1, mut shell_txf) {',
		'\t\t\tch.send(shell_txf)',
		'\t\t}',
	]
}

fn shell_manifest_frames(m Model) []string {
	if !m.shell.on {
		return []string{}
	}
	sbus := if m.shell.bus != '' { m.shell.bus } else { m.telem.bus }
	return [
		'# shell frames: frame,id,bus',
		'in,0x${m.shell.in_id.hex()},${sbus}',
		'fc,0x${m.shell.fc_id.hex()},${sbus}',
		'out,0x${m.shell.out_id.hex()},${sbus}',
	]
}
