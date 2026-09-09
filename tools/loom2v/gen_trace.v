// loom2v's TRACE codegen — thin, cohesive, in one file (docs/com-modules.md).
//
// Trace generation used to be ~1000 lines smeared through gen.v. The redesign: the platform owns the
// protocol (comm/trace: TraceBuffer, handle_cmd, TraceModule) and the enter/exit hooks own recording
// (ISR = Cortex-M exec-change, thread = RTOS/Loom, FB = the Loom's set_trace_hook); loom2v only WIRES
// — parse [trace], validate what the target can honour, and emit the few config-shaped fragments.
//
// This file currently generates the ThreadX exec-hook RAW STREAM (the HW-verified h735_threadx path):
// the comm thread freezes + snapshots the C ring (trace_hooks.c) on a host stop and serves it on
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
		// Only the overwrite ring is implemented: trace_hooks.c records into a flight-recorder
		// ring until a host stop freezes it (no oneshot / stop-when-full mode). A "oneshot"
		// request would silently get overwrite-until-stopped behaviour.
		if m.trace.mode != 'ring' {
			panic('loom2v: [target] kind="threadx" [trace].mode "${m.trace.mode}" is not implemented — ' +
				'the exec-hook recorder is an overwrite ring frozen by a host stop — use mode = "ring"')
		}
		if m.trace.record_id > 0x7ff {
			panic('loom2v: [target] kind="threadx" [trace].record_id 0x${m.trace.record_id.hex()} is an ' +
				'extended (29-bit) id, but the classic FDCAN backend sends 11-bit frames — use a ' +
				'standard id (<= 0x7FF)')
		}
		// The exec-hook recorder freezes only on a host stop; it has no overrun-triggered
		// freeze (m.trace.budget_us is only wired into the software packer's inline hook). A
		// [trace].trigger config would build, and then keep overwriting straight past every
		// overrun it was asked to catch.
		if m.trace.budget_us > 0 {
			panic('loom2v: [target] kind="threadx" [trace].trigger (budget_us) is not implemented — ' +
				'the exec-hook recorder records until a host stop, with no overrun freeze — ' +
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
	g << '\t\t\tif rx.id == u32(0x${m.trace.cmd_id.hex()}) && rx.len == 8 && !rx.ext { // trace.cmd -> the module'
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
		g << '\t\t\tif rx.id == u32(0x${m.trace.dump_fc_id.hex()}) && !rx.ext { // trace.dump_fc -> ISO-TP FC'
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
	g << '\t\tsched.run_profiled(osal.now_us)'
	g << '\t\tloom_t1 := osal.now_us()'
	g << '		// NO sched.account() here: run_profiled() accounts the pass itself (via'
	g << '		// run_profiled_excl -> account(busy, clock())). Calling it again charged the same'
	g << '		// pass twice, so every traced core reported roughly double its real load and a'
	g << '		// busy one clamped at 100% (codex #270 r2).'
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
		// tx_ready-gated like every other send on this loop: the trace drain above can leave the
		// Tx FIFO full for a whole burst, and an ungated send() there returns false and loses the
		// frame silently. Not updating last_telem keeps it due, so the next pass retries (emb#252).
		g << '\t\tif now - last_telem >= ${m.telem.period_us} && ch.tx_ready() {'
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
// io_here: this IMAGE hosts the io thread (a satellite image never does), so only it gets the
// preemption clock run_profiled_excl subtracts — the owner declares C.io_exec_us, a satellite not.
fn trace_fb_hooks(m Model, doc toml.Doc, app_threads []string, multi bool, io_here bool) []string {
	if !(m.trace.on && m.trace.level == 'all') {
		return []string{}
	}
	mut g := ['', 'fn trace_clock() u64 {', '\treturn C.board_now_us()', '}']
	if io_here {
		// the io thread's exec counter as a clock: run_profiled_excl subtracts its delta per handler
		g << ['', 'fn io_exec_clock() u32 {', '\treturn C.io_exec_us()', '}']
	}
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

// trace_shape_of projects the model onto ecumodel's TraceShape — the ONE definition of which ECUs
// loom2v can generate [trace] for, shared with sysmodel's trace_generated so syscheck and loom2v
// cannot disagree. `trace_host` in gen.v is derived from this too: a condition added here reaches
// the predicate and the error message together.
fn trace_shape_of(m Model, trace_bus string) ecumodel.TraceShape {
	bridged := bridge_can_buses(m)
	mut clash := false
	tb_core := m.bus_core[trace_bus] or { 0 }
	for pn in m.part.by_part.keys() {
		for b in bridged {
			if (m.part.core_of[pn] or { 0 }) == (m.bus_core[b] or { 0 }) {
				clash = true
			}
		}
	}
	// the bridge-owner loop also serves the trace bus, so the bridge's core must BE the trace
	// bus's core — a bridge elsewhere would leave the trace bus with no loop to serve it
	for b in bridged {
		if (m.bus_core[b] or { 0 }) != tb_core {
			clash = true // same refusal: the shape has no single owner core
		}
	}
	return ecumodel.TraceShape{
		threadx:             m.target.threadx
		baremetal:           m.target.on && !m.target.threadx
		partition_count:     m.part.by_part.keys().len
		trace_bus_eth:       (m.bus_kind[trace_bus] or { 'can' }) == 'eth'
		has_bridge:          m.has_can_ext || m.isotp_conns.len > 0 || m.routes.len > 0
		bridge_on_trace_bus: trace_bus in bridged
		bridge_core_clash:   clash
		bridge_count:        bridged.len
	}
}

// bridge_can_buses: the CAN buses that carry COM bridge work — external signals, an ISO-TP
// endpoint, or a route endpoint. The per-bus mirror of the has_bridge model flags, sorted for
// stable use in numbering.
fn bridge_can_buses(m Model) []string {
	mut set := map[string]bool{}
	for _, si in m.sig_of {
		if si.external && (m.bus_kind[si.bus] or { 'can' }) != 'eth' {
			set[si.bus] = true
		}
	}
	for c in m.isotp_conns {
		set[c.bus] = true
	}
	for r in m.routes {
		set[r.from_bus] = true
		set[r.to_bus] = true
	}
	mut names := set.keys()
	names.sort()
	return names
}

fn trace_shape_blocker(m Model, trace_bus string) string {
	return ecumodel.trace_shape_blocker(trace_shape_of(m, trace_bus))
}

// handler_id_base returns the GLOBAL fb id of a partition's first handler — the same numbering
// emit_manifest assigns (partition -> fb -> handler, in [[partition]] declaration order), so a
// Capture's id_base makes its records resolve to the manifest rows the host already has.
fn handler_id_base(m Model, doc toml.Doc, part string) u32 {
	mut hid := u32(0)
	for p in ecumodel.toml_arr(doc, 'partition') {
		pname := (p.as_map()['name'] or { toml.Any('') }).string()
		if pname == part {
			return hid
		}
		for c in m.part.by_part[pname] {
			cm := c.as_map()
			hid += u32((cm['handler'] or { toml.Any([]toml.Any{}) }).array().len)
		}
	}
	return hid
}

// emit_run_trace_multicore emits the P3a host multi-core runner (docs/trace-multicore.md §3):
// TWO partitions on two cores, each capturing into its OWN ring, one dump owner.
//
// The owner is the app partition on the trace bus's core — NOT a separate bus thread. That is the
// whole reason this shape works with the platform as it stands: the owner's ring is then genuinely
// local (m.buf), so handle_cmd's arm/stop/dump and the status counts apply to a real producing
// ring rather than to a staging copy, and only the SATELLITE needs importing. A separate owner
// thread would make both cores remote and force the protocol's state reporting to be re-derived
// here, in generated code — exactly what docs/com-modules.md keeps in the platform.
//
// run() OWNS the satellite's ring, its capture context and the import staging, and passes them in;
// it then waits on both threads, so they outlive every use. Deliberately not __global: the host
// examples build without -enable-globals, and a global would need runtime assignment anyway to
// stay clear of the _vinit trap (scripts/lint_vinit.sh, emb#134). Two threads touch the ring —
// the satellite writes, the owner reads under the freeze on_cmd_multicore applies — so it is one
// writer and one reader, never a shared write path.
fn emit_run_trace_multicore(m Model, doc toml.Doc, all_regs map[string][]string, telem_iface string, owner string, sat string) []string {
	if m.trace.level != 'fb' {
		panic('loom2v: [trace] level "${m.trace.level}" is not generated for the host multi-core ' +
			'runner — a polled host superloop has no preemptive thread or ISR events to capture, ' +
			'so it records FB dispatches (level = "fb")')
	}
	// Without dump_fc the dump is the RAW record stream, which streams m.buf only: it has no block
	// framing, so it cannot say which core a record came from. The satellite's window would be
	// imported and then never sent, leaving remote_due latched true forever. Multi-core needs the
	// self-describing ISO-TP block dump.
	if !m.trace.dump_fc_bound {
		panic('loom2v: [trace] on two partitions needs `dump_fc` bound — the multi-core dump ' +
			'streams one SELF-DESCRIBING block per core (ISO-TP), and the raw record stream that ' +
			'an unbound dump_fc selects carries no core identity, so the second core could never ' +
			'be read back (docs/trace-multicore.md §3)')
	}
	// CpuLoad is sent from this runner on the TRACE channel — it owns the only bus here. A
	// [telemetry] bus pointing somewhere else would be silently misrouted onto the trace bus.
	// Compare the RESOLVED trace bus: an omitted [trace].bus deliberately inherits the telemetry
	// bus, and comparing the raw empty field rejected exactly that documented arrangement.
	resolved_trace_bus := if m.trace.bus != '' { m.trace.bus } else { m.telem.bus }
	if m.telem.on && telem_iface != '' && m.telem.bus != '' && m.telem.bus != resolved_trace_bus {
		panic('loom2v: [telemetry].bus "${m.telem.bus}" differs from the trace bus ' +
			'"${resolved_trace_bus}", but the multi-core trace runner owns only the trace channel ' +
			'and would send CpuLoad there — put both on one bus, or drop [telemetry]')
	}
	// The multicore coherence contract is the flight recorder's: a TRIGGER on either core
	// freezes both. A oneshot COMPLETING is not a trigger — it stops its own core silently,
	// and no rule says whose completion should freeze whom — so a "coherent" two-core oneshot
	// has no defined owner and the windows drift apart at different handler rates (codex #271
	// r9). Reject it rather than generate a shape whose central promise cannot hold.
	if m.trace.mode == 'oneshot' {
		panic('loom2v: [trace] mode = "oneshot" is not generated for the multicore host runner — ' +
			'the system-wide freeze contract is trigger-based (a oneshot completing freezes only ' +
			'itself, so the two windows cannot be kept coherent) — use mode = "ring"')
	}
	mode := '.ring'
	cap := m.trace.buffer_records
	sat_core := m.part.core_of[sat] or { 0 }
	owner_core := m.part.core_of[owner] or { 0 }
	// produce() streams the LOCAL window before the imported one, so the owner's core must be the
	// lower id for the dump to arrive in ascending core order as the protocol specifies. The
	// owner is fixed by the trace bus's core, so this is a real (if narrow) config restriction —
	// state it rather than emit a stream whose block order contradicts the documented contract.
	if owner_core > sat_core {
		panic('loom2v: the trace bus is on core ${owner_core}, which makes it the dump owner, but ' +
			'the satellite sits on the lower core ${sat_core} — the owner streams its own window ' +
			'first, so the blocks would arrive in descending core order. Put the trace bus on the ' +
			'lower-numbered core (docs/trace-multicore.md §3)')
	}
	telem_on := m.telem.on && telem_iface != ''
	// Each core publishes its load to osal.scratch_set(core, ...) — 16 slots is the platform's.
	// A core id past them would not collide with anything, it would just be silently dropped by
	// scratch_set's bounds check and report a permanent zero load in the telemetry frame, with
	// nothing saying why. And with telemetry ON the ceiling is LOWER: the CpuLoad frame packs
	// one byte per core (telem.cpuload_max_cores = 8), so a core past 7 indexes the generated
	// [8]u16 load array out of bounds. Refuse both at generation instead.
	if owner_core >= 16 || sat_core >= 16 {
		panic('loom2v: [[partition]] core ${owner_core}/${sat_core} is outside the osal scratch ' +
			'area (16 slots, one per core for load telemetry) — scratch_set would silently drop ' +
			'that core\'s load and the telemetry frame would read 0 forever. Use cores 0..15.')
	}
	if telem_on && (owner_core >= 8 || sat_core >= 8) {
		panic('loom2v: [[partition]] core ${owner_core}/${sat_core} does not fit the CpuLoad ' +
			'frame — telem.cpuload_max_cores packs one byte per core for cores 0..7, and the ' +
			'generated load array is indexed by core id. Use cores 0..7, or disable [telemetry].')
	}
	mut g := []string{}

	// --- the satellite partition: its own ring, no bus ---
	g << ''
	g << '// The satellite core: it pushes FB records into the ring run() handed it, and never'
	g << '// touches the bus. The owner reads that ring only while it is frozen.'
	g << 'pub fn partition_${sat}(cap_ptr &trace.Capture) {'
	g << '	osal.pin_to_core(${sat_core})'
	g << '	mut st := Partition_${sat}_state{}'
	g << '	mut sched := loom.Scheduler{}'
	for r in all_regs[sat] or { []string{} } {
		g << r
	}
	g << '	sched.set_trace_hook(trace.fb_hook, voidptr(cap_ptr))'
	g << '	for {'
	g << '		sched.run_profiled(osal.now_us)'
	g << '		// NO sched.account() here: run_profiled() accounts the pass itself (via'
	g << '		// run_profiled_excl -> account(busy, clock())). Calling it again charged the same'
	g << '		// pass twice, so every traced core reported roughly double its real load and a'
	g << '		// busy one clamped at 100% (codex #270 r2).'
	g << '		osal.scratch_set(${sat_core}, u64(sched.load_permille()))'
	g << '		osal.sleep_us(1000)'
	g << '	}'
	g << '}'

	// --- the owner partition: its own handlers, its own ring, and the bus ---
	g << ''
	g << '// The dump owner: an ordinary app partition that also owns the trace bus. Its ring is'
	g << '// the module\'s OWN buffer, so commands and status apply to a real producing ring.'
	g << 'pub fn partition_${owner}(chp can.Channel, sat_buf &trace.TraceBuffer, import_buf &trace.Record, origin_us u64, freeze &u32) {'
	g << '	osal.pin_to_core(${owner_core})'
	g << '	mut ch := chp'
	g << '	mut sat := unsafe { sat_buf }'
	g << '	mut st := Partition_${owner}_state{}'
	g << '	mut sched := loom.Scheduler{}'
	for r in all_regs[owner] or { []string{} } {
		g << r
	}
	g << '	mut ring := [${cap}]trace.Record{}'
	g << '	mut tm := trace.new_module(u32(0x${m.trace.rsp_id.hex()}), u32(0x${m.trace.record_id.hex()}), ${owner_core}, ${m.trace.dump_fc_bound},'
	g << '		trace.new_buffer(&ring[0], ${cap}, ${mode}, ${m.trace.pre_pct}))'
	// ONE origin for both cores, taken in run() before either thread starts. Sampling it inside
	// each thread instead made every record relative to a different zero, so the two lanes were
	// skewed by the nondeterministic thread-start delay — and nothing reported it, because
	// load_remote_buffer emits no core-offset record when the clock is shared, which it is.
	g << '	mut cap := tm.capture(${handler_id_base(m, doc, owner)}, ${m.trace.budget_us}, origin_us)'
	g << '	unsafe {'
	g << '		cap.freeze = freeze // share the cross-core freeze cell with the satellite'
	g << '	}'
	g << '	tm.set_freeze(freeze) // ...and with the module, which retires it on arm/start/reset'
	g << '	sched.set_trace_hook(trace.fb_hook, &cap)'
	g << '	// both rings record from startup, like the satellite\'s below — a flight recorder that'
	g << '	// waits for a host to arm it has nothing to say about the boot it was installed to watch.'
	g << '	tm.arm()'
	if telem_on {
		g << '	mut last_telem := u64(0)'
	}
	g << '	mut rx := can.Frame{}'
	g << '	mut txf := can.Frame{}'
	g << '	for {'
	g << '		sched.run_profiled(osal.now_us)'
	g << '		loom_t1 := osal.now_us()'
	g << '		// NO sched.account() here: run_profiled() accounts the pass itself (via'
	g << '		// run_profiled_excl -> account(busy, clock())). Calling it again charged the same'
	g << '		// pass twice, so every traced core reported roughly double its real load and a'
	g << '		// busy one clamped at 100% (codex #270 r2).'
	g << '		osal.scratch_set(${owner_core}, u64(sched.load_permille()))'
	g << '		for ch.recv(mut rx) {'
	g << '			match rx.id {'
	g << '				u32(0x${m.trace.cmd_id.hex()}) { // trace.cmd — applied to BOTH cores;'
	g << '				// an arm/start/reset also retires the shared freeze (set_freeze above),'
	g << '				// BEFORE any ring restarts — retired after, a peer dispatch in the gap'
	g << '				// re-froze the just-armed ring from the stale cell.'
	g << '					tm.on_cmd_multicore(rx, mut sat, ${sat_core}, import_buf, ${cap + 1})'
	g << '				}'
	if m.trace.dump_fc_bound {
		g << '				u32(0x${m.trace.dump_fc_id.hex()}) { tm.on_dump_fc(loom_t1, rx) } // trace.dump_fc'
	}
	g << '				else {}'
	g << '			}'
	g << '		}'
	g << '		for ch.tx_ready() && tm.produce(loom_t1, mut txf) {'
	g << '			ch.send(txf)'
	g << '		}'
	if telem_on {
		g << '		now := osal.now_us()'
		g << '		if now - last_telem >= ${m.telem.period_us} && ch.tx_ready() {'
		g << '			last_telem = now'
		// encode_cpuload indexes by the REAL core id, so a config with the owner on core 1 and
		// the satellite on core 0 would report the two loads swapped if these were hardcoded 0/1.
		ncores := if owner_core > sat_core { owner_core + 1 } else { sat_core + 1 }
		g << '			mut load := [8]u16{}'
		g << '			load[${owner_core}] = u16(osal.scratch_get(${owner_core}))'
		g << '			load[${sat_core}] = u16(osal.scratch_get(${sat_core}))'
		g << '			frame := telem.encode_cpuload(load, ${ncores})'
		g << '			mut cf := can.Frame{'
		g << '				id:  u32(0x${m.telem.id.hex()})'
		g << '				len: 8'
		g << '			}'
		g << '			for j in 0 .. 8 {'
		g << '				cf.data[j] = frame[j]'
		g << '			}'
		g << '			ch.send(cf)'
		g << '		}'
	}
	g << '		osal.sleep_us(1000)'
	g << '	}'
	g << '}'

	// --- run(): own the shared ring, then spawn both cores ---
	g << ''
	g << 'pub fn run(chp can.Channel) {'
	g << '	// run() owns these and waits on both threads below, so they outlive every use.'
	g << '	mut sat_ring := [${cap}]trace.Record{}'
	g << '	mut sat_buf := trace.new_buffer(&sat_ring[0], ${cap}, ${mode}, ${m.trace.pre_pct})'
	g << '	sat_buf.start()'
	g << '	// one capture origin for BOTH cores: a per-thread origin would skew the two lanes by'
	g << '	// the thread-start delay, invisibly (a shared clock emits no core-offset record).'
	g << '	trace_origin := osal.now_us()'
	g << '	// the shared cross-core freeze cell (docs/trace-multicore.md §3). Both captures point at'
	g << '	// it, so whichever ring trips its budget raises it and the peer observes it inside its'
	g << '	// capture hook — within one handler of the event, not at the end of a scheduler pass.'
	g << '	mut trace_freeze := u32(0)'
	g << '	mut sat_cap := trace.Capture{'
	g << '		buf:       &sat_buf'
	g << '		start:     trace_origin'
	g << '		id_base:   ${handler_id_base(m, doc, sat)}'
	g << '		budget_us: ${m.trace.budget_us}'
	g << '		freeze:    unsafe { &trace_freeze }'
	g << '	}'
	g << '	// staging for the imported window (caller-owned, per set_remote): +1 for the leading'
	g << '	// core-offset record load_remote_buffer may prepend.'
	g << '	mut import_ring := [${cap + 1}]trace.Record{}'
	g << '	t_${sat} := spawn partition_${sat}(&sat_cap)'
	g << '	t_${owner} := spawn partition_${owner}(chp, &sat_buf, unsafe { &import_ring[0] }, trace_origin,'
	g << '		unsafe { &trace_freeze })'
	g << '	t_${sat}.wait()'
	g << '	t_${owner}.wait()'
	g << '}'
	return g
}
