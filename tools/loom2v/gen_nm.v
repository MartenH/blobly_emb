// loom2v's NM codegen — thin wiring for comm/nm_can's NmModule (docs/com-modules.md): parse
// the [nm] endpoint bindings, emit the router range arm + produce drain into the comm thread,
// and advertise the frames in the manifest. The third module through the endpoint-binding
// pattern (after trace and shell) and the first with a RANGE rx endpoint — the cluster's NM
// traffic is an id range, not one frame. The protocol lives entirely in comm/nm + comm/nm_can.
module main

import toml
import comm.nm_can

const nm_config_keys = ['enabled', 'bus', 'node', 'pn', 'request', 'msg_cycle_ms', 'timeout_ms',
	'repeat_ms', 'wait_sleep_ms']

struct NmCfg {
mut:
	on       bool
	bus      string
	node     u8
	pn       u64
	request  bool = true // request the bus at boot (this ECU's COM needs it up)
	alive_id u32
	peers_lo u32 = 0x500
	peers_hi u32 = 0x53F
	// timings, ms in config (docs/nm.md) — µs on the wire types
	cycle_ms   u32 = 100
	timeout_ms u32 = 300
	repeat_ms  u32 = 200
	wait_ms    u32 = 150
}

fn parse_nm(doc toml.Doc, dbc string) NmCfg {
	mut t := NmCfg{}
	ncfg := doc.value_opt('nm') or { return t }
	full := ncfg.as_map()
	// [nm] carries both worlds: scalar keys are the module bindings (this parser); a
	// TABLE-valued key is a legacy cfg2v per-network block ([nm.can0] -> gen.nm_can0_*
	// constants), consumed by cfg2v and skipped here. Legacy-only = no module.
	mut sm := map[string]toml.Any{}
	for k, v in full {
		if v !is map[string]toml.Any {
			sm[k] = v
		}
	}
	if sm.len == 0 {
		return t
	}
	t.on = (sm['enabled'] or { toml.Any(true) }).bool()
	if !t.on {
		return t
	}
	mut endpoint_names := []string{}
	for e in nm_can.endpoints {
		endpoint_names << e.name
	}
	for k, _ in sm {
		if k !in nm_config_keys && k !in endpoint_names {
			panic('loom2v: [nm] unknown key "${k}" — endpoints: ${endpoint_names}, ' +
				'config: ${nm_config_keys}')
		}
	}
	t.bus = (sm['bus'] or { toml.Any('') }).string()
	node := (sm['node'] or { panic('loom2v: [nm] needs node = <this ECU source node id, 0..255>') }).int()
	if node < 0 || node > 255 {
		panic('loom2v: [nm] node must be 0..255, got ${node}')
	}
	t.node = u8(node)
	t.pn = u64((sm['pn'] or { toml.Any(0) }).int())
	t.request = (sm['request'] or { toml.Any(true) }).bool()
	t.cycle_ms = u32((sm['msg_cycle_ms'] or { toml.Any(100) }).int())
	t.timeout_ms = u32((sm['timeout_ms'] or { toml.Any(300) }).int())
	t.repeat_ms = u32((sm['repeat_ms'] or { toml.Any(200) }).int())
	t.wait_ms = u32((sm['wait_sleep_ms'] or { toml.Any(150) }).int())
	for e in nm_can.endpoints {
		match e.name {
			'peers' {
				// a RANGE endpoint binds an inclusive [lo, hi] TOML array, not one id
				if v := sm['peers'] {
					arr := v.array()
					if arr.len != 2 {
						panic('loom2v: [nm] peers must be an inclusive range [lo, hi]')
					}
					t.peers_lo = u32(arr[0].int())
					t.peers_hi = u32(arr[1].int())
					if t.peers_hi < t.peers_lo {
						panic('loom2v: [nm] peers range is inverted (hi < lo)')
					}
				}
			}
			'alive' {
				// conventionally base + node; an explicit binding overrides
				t.alive_id = trace_binding(sm, e.name, e.dlc, t.peers_lo + u32(t.node), dbc)
			}
			else {
				panic('loom2v: comm.nm_can endpoint "${e.name}" has no NmCfg field — teach parse_nm about it')
			}
		}
	}
	return t
}

fn nm_module_globals(m Model) []string {
	if !m.nm.on {
		return []string{}
	}
	return ['\tg_nm nm_can.NmModule']
}

fn nm_module_init(m Model) []string {
	if !m.nm.on {
		return []string{}
	}
	mut g := []string{}
	g << '\tg_nm.init(u8(0x${m.nm.node.hex()}), u32(0x${m.nm.alive_id.hex()}), u64(${m.nm.pn}), nm.Timings{'
	g << '\t\tmsg_cycle_us:  ${u64(m.nm.cycle_ms) * 1000}'
	g << '\t\ttimeout_us:    ${u64(m.nm.timeout_ms) * 1000}'
	g << '\t\trepeat_us:     ${u64(m.nm.repeat_ms) * 1000}'
	g << '\t\twait_sleep_us: ${u64(m.nm.wait_ms) * 1000}'
	g << '\t})'
	if m.nm.request {
		g << "\tg_nm.request(C.board_now_us()) // this ECU's COM needs the bus from boot ([nm] request)"
	}
	g << '\tmut nm_txf := can.Frame{}'
	return g
}

// nm_rx_arms: the router arm — the first RANGE arm (the cluster's NM ids). Emitted after the
// single-id modules so an overlapping single-id binding still wins its frame.
fn nm_rx_arms(m Model) []string {
	if !m.nm.on {
		return []string{}
	}
	return [
		'\t\t\tif rx.id >= u32(0x${m.nm.peers_lo.hex()}) && rx.id <= u32(0x${m.nm.peers_hi.hex()}) { // nm.peers -> cluster NM',
		'\t\t\t\tg_nm.on_peers(C.board_now_us(), rx)',
		'\t\t\t}',
	]
}

fn nm_produce_drain(m Model) []string {
	if !m.nm.on {
		return []string{}
	}
	return [
		'\t\tfor ch.tx_ready() && g_nm.produce(t1, mut nm_txf) {',
		'\t\t\tch.send(nm_txf)',
		'\t\t}',
	]
}

fn nm_manifest_frames(m Model) []string {
	if !m.nm.on {
		return []string{}
	}
	nbus := if m.nm.bus != '' { m.nm.bus } else { m.telem.bus }
	return [
		'# nm frames: frame,id,bus',
		'alive,0x${m.nm.alive_id.hex()},${nbus}',
		'peers_lo,0x${m.nm.peers_lo.hex()},${nbus}',
		'peers_hi,0x${m.nm.peers_hi.hex()},${nbus}',
	]
}

// nm_shell_fns / nm_shell_register: the `nm` shell command (state; nm req|rel) — shell and NM
// are both comm-thread modules, so this is the com-modules "same thread = direct call" rule.
fn nm_shell_fns(m Model) []string {
	if !m.nm.on || !m.shell.on {
		return []string{}
	}
	return [
		'',
		'fn shell_nm_cmd(args &u8, args_len int, now u64, mut rsp shell.Rsp) {',
		'\tif args_len >= 3 && unsafe { args[0] } == `r` && unsafe { args[1] } == `e` {',
		'\t\tif unsafe { args[2] } == `q` {',
		'\t\t\tg_nm.request(now)',
		'\t\t} else {',
		'\t\t\tg_nm.release()',
		'\t\t}',
		'\t}',
		'\trsp.write(g_nm.state_str())',
		'\trsp.nl()',
		'}',
	]
}

fn nm_shell_register(m Model) []string {
	if !m.nm.on || !m.shell.on {
		return []string{}
	}
	return ["\tg_sh.register('nm', 'NM state; nm req|rel', shell_nm_cmd)"]
}
