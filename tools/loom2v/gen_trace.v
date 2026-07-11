// loom2v's TRACE codegen — thin, cohesive, in one file (docs/com-modules.md).
//
// Trace generation used to be ~1000 lines smeared through gen.v. The redesign: the platform owns the
// protocol (comm/trace: TraceBuffer, handle_cmd, TraceModule) and the enter/exit hooks own recording
// (ISR = Cortex-M exec-change, thread = RTOS/Loom, FB = the Loom's set_trace_hook); loom2v only WIRES
// — parse [trace], validate what the target can honour, and emit the few config-shaped fragments.
//
// This file currently generates the ThreadX exec-hook RAW STREAM (the HW-verified h735_threadx path):
// the comm thread snapshots the C ring (trace_hooks.c) ~1 s and streams raw 8-byte records on
// record_id, tx_ready-gated. The host command-driven protocol (arm/stop/dump via routed TraceCmd)
// is served by comm/trace's TraceModule and lands via frame->module routing — not generated here.
module main

import os
import toml
import tools.candb
import comm.trace

// The [trace] config keys that are NOT endpoint bindings. Everything else in the block must be
// an endpoint name from comm.trace's schema — anything unknown fails generation.
const trace_config_keys = ['enabled', 'bus', 'level', 'mode', 'buffer_records', 'pre_pct',
	'push_ms', 'trigger']

// TraceCfg is the parsed [trace] block. Endpoint ids default to the docs/telemetry.md convention;
// sw_keys records which software-packer-only keys were set EXPLICITLY (so the ThreadX exec-hook
// path can reject them without rejecting a bare config).
struct TraceCfg {
mut:
	on             bool
	bus            string
	cmd_id         u32 = 0x7E2
	rsp_id         u32 = 0x7E3
	record_id      u32 = 0x7E5
	level          string = 'thread+fb'
	mode           string = 'ring'
	buffer_records int = 64
	pre_pct        int = 50
	push_us        u64 = 1_000_000
	budget_us      u64 // overrun trigger budget (0 = no software trigger)
	sw_keys        []string
}

// parse_trace parses the [trace] block: config keys plus one BINDING per module endpoint —
// `cmd = "TraceCmd"` / `record = 0x7E5` (a bus.dbc message name or a literal id), validated
// against comm.trace's endpoint schema (docs/com-modules.md): an unknown key fails generation
// listing the valid names, and a name binding's DLC must match the endpoint's declared dlc.
// A block is active unless enabled = false; bindings resolve against the DBC only when active.
fn parse_trace(doc toml.Doc, dbc string) TraceCfg {
	mut t := TraceCfg{}
	if trcfg := doc.value_opt('trace') {
		trm := trcfg.as_map()
		t.on = (trm['enabled'] or { toml.Any(true) }).bool()
		t.bus = (trm['bus'] or { toml.Any('') }).string()
		// Every key must be a config key or a schema endpoint — catch typos and stale keys at
		// generation, not as silently-ignored config.
		mut endpoint_names := []string{}
		for e in trace.endpoints {
			endpoint_names << e.name
		}
		for k, _ in trm {
			if k !in trace_config_keys && k !in endpoint_names {
				panic('loom2v: [trace] unknown key "${k}" — endpoints: ${endpoint_names}, ' +
					'config: ${trace_config_keys}')
			}
		}
		if t.on {
			for e in trace.endpoints {
				match e.name {
					'cmd' { t.cmd_id = trace_binding(trm, e.name, e.dlc, t.cmd_id, dbc) }
					'rsp' { t.rsp_id = trace_binding(trm, e.name, e.dlc, t.rsp_id, dbc) }
					'record' { t.record_id = trace_binding(trm, e.name, e.dlc, t.record_id, dbc) }
					else { panic('loom2v: comm.trace endpoint "${e.name}" has no TraceCfg field — teach parse_trace about it') }
				}
			}
		}
		t.level = (trm['level'] or { toml.Any(t.level) }).string()
		t.mode = (trm['mode'] or { toml.Any(t.mode) }).string()
		t.buffer_records = int((trm['buffer_records'] or { toml.Any(t.buffer_records) }).int())
		t.pre_pct = int((trm['pre_pct'] or { toml.Any(t.pre_pct) }).int())
		if pms := trm['push_ms'] {
			t.push_us = u64(pms.int()) * 1000
		}
		for k in ['cmd', 'push_ms', 'pre_pct'] {
			if k in trm {
				t.sw_keys << k
			}
		}
		// trigger = { source = "overrun", budget_us = N }: freeze the ring when a handler runs
		// longer than N µs. Only "overrun" is generated today; other sources are reserved.
		if tg := trm['trigger'] {
			tgm := tg.as_map()
			if (tgm['source'] or { toml.Any('') }).string() == 'overrun' {
				t.budget_us = u64((tgm['budget_us'] or { toml.Any(0) }).int())
			}
		}
	}
	return t
}

// trace_binding resolves one endpoint binding: a literal number is the CAN id (used as-is —
// a colliding id is the author's problem); a string is a bus.dbc message name that must exist,
// its id is used, and its DLC must match the endpoint's declared dlc (validate at generation,
// per docs/com-modules.md "sizes must match").
fn trace_binding(trm map[string]toml.Any, key string, want_dlc u8, def u32, dbc string) u32 {
	v := trm[key] or { return def }
	if v is string {
		db := candb.load_dbc_file(dbc) or {
			panic('loom2v: [trace] ${key} = "${v}" is a bus.dbc message name but ${os.file_name(dbc)} did not load: ${err}')
		}
		id := dbc_id_of(db, snake(v)) or {
			panic('loom2v: [trace] ${key} = "${v}" is not a message in ${os.file_name(dbc)}')
		}
		if want_dlc > 0 {
			dlc := dbc_dlc_of(db, snake(v)) or { 0 }
			if dlc != int(want_dlc) {
				panic('loom2v: [trace] ${key} = "${v}" has dlc ${dlc} in ${os.file_name(dbc)}, but ' +
					'the trace.${key} endpoint sends/expects ${want_dlc} bytes')
			}
		}
		return u32(id)
	}
	// A literal id must be a legal CAN identifier — read as i64 (so a >32-bit value doesn't
	// wrap) and reject out-of-range before it becomes a bogus manifest frame.
	n := v.i64()
	if n < 0 || n > 0x1fff_ffff {
		panic('loom2v: [trace] ${key} ${n} is not a valid CAN id (0..0x1FFFFFFF)')
	}
	return u32(n)
}

// validate_trace_threadx rejects [trace] configs the ThreadX exec-hook stream cannot honour —
// fail generation rather than emit code that silently ignores config.
fn validate_trace_threadx(m Model) {
	// ThreadX target trace is the RAW exec-hook stream: THREAD/ISR records only, one classic
	// 11-bit frame per record, streamed by the single bus owner on the telemetry channel. No
	// TraceCmd/Rsp/HandlerStat/ISO-TP. Reject configs it can't honour rather than emit code
	// that silently ignores them.
	if m.target.threadx && m.trace.on {
		// The exec-change hooks fire on BOTH context switches and ISR enter/exit unconditionally,
		// so the stream is always exactly "thread+isr" — a "thread"-only or FB-inclusive level
		// can't be honoured. Reject anything but the one level the hooks actually produce.
		if m.trace.level != 'thread+isr' {
			panic('loom2v: [target] kind="threadx" [trace].level "${m.trace.level}" is not producible — ' +
				'the exec-change hooks always capture context switches AND ISRs (no thread-only, no ' +
				'handler-level FB records) — use level = "thread+isr"')
		}
		// Only the overwrite ring is implemented (trace_hooks.c has no oneshot/stop-when-full ring),
		// and the generated stream re-snapshots every ~1 s. A "oneshot" request would silently get
		// continuous ring behaviour.
		if m.trace.mode != 'ring' {
			panic('loom2v: [target] kind="threadx" [trace].mode "${m.trace.mode}" is not implemented — ' +
				'the exec-hook recorder is an overwrite ring streamed continuously — use mode = "ring"')
		}
		if m.trace.record_id > 0x7ff {
			panic('loom2v: [target] kind="threadx" [trace].record_id 0x${m.trace.record_id.hex()} is an ' +
				'extended (29-bit) id, but the classic FDCAN backend sends 11-bit frames — use a ' +
				'standard id (<= 0x7FF)')
		}
		// The exec-hook path snapshots and streams the ring on a fixed ~1 s cadence; it has no
		// overrun-triggered freeze (m.trace.budget_us is only wired into the software packer's inline
		// hook). A [trace].trigger config would build but silently produce a continuous ring.
		if m.trace.budget_us > 0 {
			panic('loom2v: [target] kind="threadx" [trace].trigger (budget_us) is not implemented — ' +
				'the exec-hook recorder streams the ring on a fixed cadence with no overrun freeze — ' +
				'drop the trigger for threadx builds')
		}
		// The exec-hook stream is raw records only: no TraceCmd request path, no HandlerStat
		// heartbeat, no pre-trigger split. These keys have working defaults but are inert here,
		// so an explicitly-set one (copied from a host trace block) would build while silently
		// doing nothing. Reject the explicit ones rather than ignore them.
		if m.trace.sw_keys.len > 0 {
			panic('loom2v: [target] kind="threadx" [trace] key(s) ${m.trace.sw_keys} are not implemented — ' +
				'the exec-hook stream has no TraceCmd request path (cmd), HandlerStat heartbeat ' +
				'(push_ms), or pre-trigger split (pre_pct); it streams only raw records on the ' +
				'record binding — remove these keys for threadx builds')
		}
		if m.trace.bus != '' && m.trace.bus != m.telem.bus {
			panic('loom2v: [target] kind="threadx" [trace].bus "${m.trace.bus}" must equal ' +
				'[telemetry].bus "${m.telem.bus}" — the single bus owner streams both on one channel')
		}
	}
}

// trace_c_decls: the extern for trace_hooks.c's snapshot (the C ring copier).
fn trace_c_decls(m Model) []string {
	if !m.trace.on {
		return []string{}
	}
	return [
		'fn C.trace_snapshot(voidptr, u32) u32',
	]
}

// trace_scratch_fields: the owner's stable snapshot buffer (a struct field of the comm state).
fn trace_scratch_fields(m Model, part string) []string {
	if !m.trace.on {
		return []string{}
	}
	return [
		'\tg_${part}_trace [${m.trace.buffer_records}][8]u8 // scratch snapshot of the trace ring (owner streams it)',
	]
}

// trace_stream_state: the stream's loop-local state vars.
fn trace_stream_state(m Model) []string {
	if !m.trace.on {
		return []string{}
	}
	return [
		'\tmut last_trace := u64(0)',
		'\tmut tr_pos := u32(0)',
		'\tmut tr_n := u32(0)',
		'\tmut tr_active := false',
	]
}

// trace_stream: the exec-hook ring stream inside the bus-owner loop — snapshot ~1 s, then send raw
// 8-byte records in tx_ready-gated 16-record chunks (a stuck bus can't wedge the owner).
fn trace_stream(m Model, part string) []string {
	if !m.trace.on {
		return []string{}
	}
	mut g := []string{}
	g << '\t\t// PRODUCER: exec-hook trace ring (a burst -> tx_ready-gated 16-record chunks)'
	g << '\t\tif !tr_active && t1 - last_trace >= u64(1000000) {'
	g << '\t\t\ttr_n = C.trace_snapshot(&g_${part}_trace[0], ${m.trace.buffer_records})'
	g << '\t\t\ttr_pos = 0'
	g << '\t\t\ttr_active = true'
	g << '\t\t}'
	g << '\t\tif tr_active {'
	g << '\t\t\tmut sent := 0'
	g << '\t\t\tfor tr_pos < tr_n && sent < 16 && ch.tx_ready() {'
	g << '\t\t\t\tmut tf := can.Frame{'
	g << '\t\t\t\t\tid:  u32(0x${m.trace.record_id.hex()})'
	g << '\t\t\t\t\tlen: 8'
	g << '\t\t\t\t}'
	g << '\t\t\t\tfor j in 0 .. 8 {'
	g << '\t\t\t\t\ttf.data[j] = g_${part}_trace[tr_pos][j]'
	g << '\t\t\t\t}'
	g << '\t\t\t\tch.send(tf)'
	g << '\t\t\t\ttr_pos++'
	g << '\t\t\t\tsent++'
	g << '\t\t\t}'
	g << '\t\t\tif tr_pos >= tr_n {'
	g << '\t\t\t\ttr_active = false'
	g << '\t\t\t\tlast_trace = C.board_now_us()'
	g << '\t\t\t}'
	g << '\t\t}'
	return g
}

// trace_manifest_timer_row: the hidden ThreadX System Timer Thread takes the id right after the
// AUTO_START app threads (trace_hooks.c assigns ids by first sight) — without this row blobly_net
// sees an unlabelled THREAD lane.
fn trace_manifest_timer_row(m Model, tid int) []string {
	if !(m.target.threadx && m.trace.on) {
		return []string{}
	}
	return ['thread,${tid},tx_system_timer,0']
}

// trace_manifest_frames: the observability frame ids blobly_net decodes natively — exactly what
// each shape actually sends: the ThreadX target streams only raw records; the host module also
// serves the TraceCmd/TraceRsp pair.
fn trace_manifest_frames(m Model, trace_host bool) []string {
	if !m.trace.on {
		return []string{}
	}
	tbus := if m.trace.bus != '' { m.trace.bus } else { m.telem.bus }
	mut rows := ['# trace frames: frame,id,bus']
	if trace_host {
		rows << 'cmd,0x${m.trace.cmd_id.hex()},${tbus}'
		rows << 'rsp,0x${m.trace.rsp_id.hex()},${tbus}'
	}
	rows << 'record,0x${m.trace.record_id.hex()},${tbus}'
	return rows
}

// emit_run_trace_host emits the single-core host run(ch) for a traced app: ONE loop owns the bus
// and the schedule, so the FB hook, the module's ring, and the bus side share a thread (no locks,
// single owner). The trace protocol itself is comm/trace's TraceModule — this only WIRES it: build
// the ring from config, install the platform fb_hook, route the cmd binding to on_cmd (the
// generated router match, docs/com-modules.md), drain produce, and send CpuLoad inline.
fn emit_run_trace_host(m Model, all_regs map[string][]string, telem_iface string, part string) []string {
	if m.trace.level != 'fb' {
		panic('loom2v: [trace] level "${m.trace.level}" is not generated for the host module runner — ' +
			'it captures FB records via the Loom hook (level = "fb"); thread spans are the follow-up')
	}
	mode := if m.trace.mode == 'oneshot' { '.oneshot' } else { '.ring' }
	telem_on := m.telem.on && telem_iface != ''
	mut g := []string{}
	g << ''
	g << 'pub fn run(chp can.Channel) {'
	g << '\tosal.pin_to_core(${m.bus_core[m.trace.bus] or { 0 }})'
	g << '\tmut ch := chp'
	g << '\tmut st := Partition_${part}_state{}'
	g << '\tmut sched := loom.Scheduler{}'
	for r in all_regs[part] or { []string{} } {
		g << r
	}
	g << '\t// trace: the ring + module (comm/trace) — the platform serves the protocol, this loop'
	g << '\t// only feeds it: fb_hook records each dispatched handler, on_cmd applies routed commands,'
	g << '\t// produce yields the response + dump stream.'
	g << '\tmut ring := [${m.trace.buffer_records}]trace.Record{}'
	g << '\tmut tm := trace.new_module(u32(0x${m.trace.rsp_id.hex()}), u32(0x${m.trace.record_id.hex()}), 0,'
	g << '\t\ttrace.new_buffer(&ring[0], ${m.trace.buffer_records}, ${mode}, ${m.trace.pre_pct}))'
	g << '\tmut cap := tm.capture(0, ${m.trace.budget_us}, osal.now_us())'
	g << '\tsched.set_trace_hook(trace.fb_hook, &cap)'
	if telem_on {
		g << '\tmut last_telem := u64(0)'
	}
	g << '\tmut rx := can.Frame{}'
	g << '\tmut txf := can.Frame{}'
	g << '\tfor {'
	g << '\t\tloom_t0 := osal.now_us()'
	g << '\t\tsched.run_profiled(osal.now_us)'
	g << '\t\tloom_t1 := osal.now_us()'
	g << '\t\tsched.account(loom_t1 - loom_t0, loom_t1) // per-core load'
	g << '\t\t// the generated router match: each rx binding dispatches to its endpoint handler'
	g << '\t\tfor ch.recv(mut rx) {'
	g << '\t\t\tmatch rx.id {'
	g << '\t\t\t\tu32(0x${m.trace.cmd_id.hex()}) { tm.on_cmd(rx) } // trace.cmd'
	g << '\t\t\t\telse {}'
	g << '\t\t\t}'
	g << '\t\t}'
	g << '\t\tfor ch.tx_ready() && tm.produce(mut txf) {'
	g << '\t\t\tch.send(txf)'
	g << '\t\t}'
	if telem_on {
		g << '\t\tnow := osal.now_us()'
		g << '\t\tif now - last_telem >= ${m.telem.period_us} {'
		g << '\t\t\tlast_telem = now'
		g << '\t\t\tmut load := [8]u16{}'
		g << '\t\t\tload[0] = u16(sched.load_permille())'
		g << '\t\t\tframe := telem.encode_cpuload(load, 1)'
		g << '\t\t\tmut cf := can.Frame{'
		g << '\t\t\t\tid:  u32(0x${m.telem.id.hex()})'
		g << '\t\t\t\tlen: 8'
		g << '\t\t\t}'
		g << '\t\t\tfor j in 0 .. 8 {'
		g << '\t\t\t\tcf.data[j] = frame[j]'
		g << '\t\t\t}'
		g << '\t\t\tch.send(cf)'
		g << '\t\t}'
	}
	g << '\t\tosal.sleep_us(1000)'
	g << '\t}'
	g << '}'
	return g
}
