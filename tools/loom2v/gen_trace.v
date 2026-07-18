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
import tools.ecumodel
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
	dump_fc_id     u32 = 0x7E6
	dump_fc_bound  bool // dump_fc bound -> the ISO-TP block dump (else the raw record stream)
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
					'dump_fc' {
						t.dump_fc_id = trace_binding(trm, e.name, e.dlc, t.dump_fc_id, dbc)
						t.dump_fc_bound = e.name in trm
					}
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
		for k in ['push_ms', 'pre_pct'] {
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
		if m.trace.level !in ['thread+isr', 'all'] {
			panic('loom2v: [target] kind="threadx" [trace].level "${m.trace.level}" is not producible — ' +
				'the exec-change hooks always capture context switches AND ISRs, and "all" adds the ' +
				'FB records via the Loom hook — use level = "thread+isr" or "all"')
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
		// The exec-hook recorder has no HandlerStat heartbeat and no pre-trigger split. These
		// keys have working defaults but are inert here, so an explicitly-set one (copied from a
		// host trace block) would build while silently doing nothing. Reject rather than ignore.
		if m.trace.sw_keys.len > 0 {
			panic('loom2v: [target] kind="threadx" [trace] key(s) ${m.trace.sw_keys} are not implemented — ' +
				'the exec-hook recorder has no HandlerStat heartbeat (push_ms) or pre-trigger ' +
				'split (pre_pct) — remove these keys for threadx builds')
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
	mut g := [
		'fn C.trace_snapshot(voidptr, u32) u32',
		'fn C.trace_arm()',
		'fn C.trace_freeze()',
		'fn C.trace_bind_thread(voidptr)',
	]
	if m.trace.level == 'all' {
		g << 'fn C.trace_fb(u32, u64, u32)'
	}
	return g
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

// trace_module_globals: the module + its ring live in __global (the ISO-TP link alone is ~1 KB
// — keep it off the 4 KB comm stack). Initialised at comm-thread start (trace_module_init).
fn trace_module_globals(m Model) []string {
	if !m.trace.on {
		return []string{}
	}
	return [
		'\tg_trace_ring [${m.trace.buffer_records}]trace.Record',
		'\tg_tm trace.TraceModule',
	]
}

// trace_module_init: construct the TraceModule from the bindings — the platform serves the
// protocol (docs/com-modules.md); dump_fc bound selects the ISO-TP block dump.
fn trace_module_init(m Model) []string {
	if !m.trace.on {
		return []string{}
	}
	return [
		'\tg_tm.init(u32(0x${m.trace.rsp_id.hex()}), u32(0x${m.trace.record_id.hex()}), 0, ${m.trace.dump_fc_bound}, // in place: no module-sized stack copy',
		'\t\ttrace.new_buffer(&g_trace_ring[0], ${m.trace.buffer_records}, .ring, 0))',
		'\tmut trace_txf := can.Frame{}',
	]
}

// trace_rx_arms: the router match arms inside the comm thread's rx drain — cmd routes to the
// module (with the exec-hook C recorder orchestrated around it: arm clears the C ring, stop
// imports the frozen window via load_snapshot so status/dump serve the real capture), dump_fc
// feeds the ISO-TP flow control.
fn trace_rx_arms(m Model, part string) []string {
	if !m.trace.on {
		return []string{}
	}
	mut g := []string{}
	g << '\t\t\tif rx.id == u32(0x${m.trace.cmd_id.hex()}) && rx.len == 8 { // trace.cmd -> the module'
	g << '\t\t\t\top := rx.data[0]'
	g << '\t\t\t\tif op == trace.op_arm || op == trace.op_start || op == trace.op_reset {'
	g << "\t\t\t\t\tC.trace_arm() // fresh window in the exec-hook recorder"
	g << '\t\t\t\t} else if op == trace.op_stop {'
	g << '\t\t\t\t\tC.trace_freeze() // stop RECORDING until the next arm — repeated dumps are identical'
	g << '\t\t\t\t\ttr_n := C.trace_snapshot(&g_${part}_trace[0], ${m.trace.buffer_records})'
	g << '\t\t\t\t\tg_tm.load_snapshot(&g_${part}_trace[0][0], tr_n)'
	g << '\t\t\t\t}'
	g << '\t\t\t\tg_tm.on_cmd(rx)'
	g << '\t\t\t}'
	if m.trace.dump_fc_bound {
		g << '\t\t\tif rx.id == u32(0x${m.trace.dump_fc_id.hex()}) { // trace.dump_fc -> ISO-TP FC'
		g << '\t\t\t\tg_tm.on_dump_fc(C.board_now_us(), rx)'
		g << '\t\t\t}'
	}
	return g
}

// trace_produce_drain: stream whatever the module has ready (response, then the dump), gated on
// tx_ready so a stuck bus never wedges the owner.
fn trace_produce_drain(m Model) []string {
	if !m.trace.on {
		return []string{}
	}
	return [
		// REQ-COM-007: silent in sleep — the response stays queued in the module
		// and goes out after wake (the link does not tick while gated).
		'\t\tfor ${nm_gate(m)}ch.tx_ready() && g_tm.produce(t1, mut trace_txf) {',
		'\t\t\tch.send(trace_txf)',
		'\t\t}',
	]
}

// trace_manifest_timer_row: the hidden ThreadX System Timer Thread takes the id right after the
// AUTO_START app threads (trace_hooks.c assigns ids by first sight) — without this row blobly_net
// sees an unlabelled THREAD lane.
fn trace_manifest_timer_row(m Model, tid int) []string {
	if !(m.target.threadx && m.trace.on) {
		return []string{}
	}
	return ['thread,${tid},tx_system_timer,0,0'] // TX_TIMER_THREAD_PRIORITY = 0: the HIGHEST — it just runs only when a tick expires a timer
}

// trace_manifest_frames: the observability frame ids blobly_net decodes natively — the module
// serves cmd/rsp + the dump on record (ISO-TP when dump_fc is bound, raw records otherwise).
fn trace_manifest_frames(m Model) []string {
	if !m.trace.on {
		return []string{}
	}
	tbus := if m.trace.bus != '' { m.trace.bus } else { m.telem.bus }
	mut rows := ['# trace frames: frame,id,bus']
	rows << 'cmd,0x${m.trace.cmd_id.hex()},${tbus}'
	rows << 'rsp,0x${m.trace.rsp_id.hex()},${tbus}'
	rows << 'record,0x${m.trace.record_id.hex()},${tbus}'
	if m.trace.dump_fc_bound {
		rows << 'dump_fc,0x${m.trace.dump_fc_id.hex()},${tbus}'
	}
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
	g << '\tmut tm := trace.new_module(u32(0x${m.trace.rsp_id.hex()}), u32(0x${m.trace.record_id.hex()}), 0, ${m.trace.dump_fc_bound},'
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
	if m.trace.dump_fc_bound {
		g << '\t\t\t\tu32(0x${m.trace.dump_fc_id.hex()}) { tm.on_dump_fc(loom_t1, rx) } // trace.dump_fc'
	}
	g << '\t\t\t\telse {}'
	g << '\t\t\t}'
	g << '\t\t}'
	g << '\t\tfor ch.tx_ready() && tm.produce(loom_t1, mut txf) {'
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

// trace_fb_hooks: the FB enter/exit family on the ThreadX target — a Loom trace hook per FB
// thread that hands each dispatched handler to the exec-hook recorder (trace_fb, IRQ-safe) so FB
// bars appear inside the thread lanes. Emitted only for level = "all". Handler ids are GLOBAL
// (manifest order: partition -> fb -> handler), but each thread's scheduler indexes its OWN
// handlers 0..n — so multi-thread emits one id table per thread mapping the local idx back to
// the global id (a thread's handlers need not be contiguous in the global numbering).
fn trace_fb_hooks(m Model, doc toml.Doc, app_threads []string, multi bool) []string {
	if !(m.trace.on && m.trace.level == 'all') {
		return []string{}
	}
	mut g := ['', 'fn trace_clock() u64 {', '\treturn C.board_now_us()', '}']
	if !multi {
		g << ''
		g << 'fn trace_fb_hook(ctx voidptr, idx int, start_us u64, dt_us u64) {'
		g << '\tC.trace_fb(u32(idx), start_us, u32(dt_us))'
		g << '}'
		return g
	}
	// global handler ids per thread, in manifest order
	mut hids := map[string][]int{}
	mut hid := 0
	for p in ecumodel.toml_arr(doc, 'partition') {
		pname := (p.as_map()['name'] or { toml.Any('') }).string()
		for c in m.part.by_part[pname] {
			cm := c.as_map()
			fbname := (cm['name'] or { toml.Any('') }).string()
			thr := m.part.fb_thread[fbname] or { app_threads[0] }
			for _ in (cm['handler'] or { toml.Any([]toml.Any{}) }).array() {
				hids[thr] << hid
				hid++
			}
		}
	}
	for thr in app_threads {
		// the local-idx -> global-id map as a match, NOT a const array: V const arrays need the
		// runtime's _vinit, which a freestanding image never runs — the array would read junk.
		g << ''
		g << 'fn trace_fb_hook_${thr}(ctx voidptr, idx int, start_us u64, dt_us u64) {'
		g << '\thid := match idx {'
		for li, h in hids[thr] or { []int{} } {
			g << '\t\t${li} { u32(${h}) }'
		}
		g << '\t\telse { u32(0x3fff) } // unknown local idx — the 14-bit id space top'
		g << '\t}'
		g << '\tC.trace_fb(hid, start_us, u32(dt_us))'
		g << '}'
	}
	return g
}

// trace_fb_install: install the hook on the FB thread's scheduler (before its loop).
fn trace_fb_install(m Model) []string {
	if !(m.trace.on && m.trace.level == 'all') {
		return []string{}
	}
	return ['\tsched.set_trace_hook(trace_fb_hook, unsafe { nil })']
}
