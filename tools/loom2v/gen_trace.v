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

// TraceCfg is the parsed [trace] block. Ids default to the docs/telemetry.md convention; sw_keys
// records which software-packer-only keys were set EXPLICITLY (so the ThreadX exec-hook path can
// reject them without rejecting a bare config).
struct TraceCfg {
mut:
	on             bool
	bus            string
	cmd_id         u32 = 0x7E2
	rsp_id         u32 = 0x7E3
	stat_id        u32 = 0x7E4
	record_id      u32 = 0x7E5
	dump_fc_id     u32 = 0x7E6
	level          string = 'thread+fb'
	mode           string = 'ring'
	buffer_records int = 64
	pre_pct        int = 50
	push_us        u64 = 1_000_000
	budget_us      u64 // overrun trigger budget (0 = no software trigger)
	sw_keys        []string
}

// parse_trace parses the [trace] block into a TraceCfg (part of the model). A block is active
// unless enabled = false; ids resolve to bus.dbc only when active (a disabled block generates
// nothing, so a stale `cmd_id = "SomeName"` must not load the DBC or panic on a missing message).
fn parse_trace(doc toml.Doc, dbc string) TraceCfg {
	mut t := TraceCfg{}
	if trcfg := doc.value_opt('trace') {
		trm := trcfg.as_map()
		t.on = (trm['enabled'] or { toml.Any(true) }).bool()
		t.bus = (trm['bus'] or { toml.Any('') }).string()
		if t.on {
			t.cmd_id = trace_frame_id(trm, 'cmd_id', t.cmd_id, dbc)
			t.rsp_id = trace_frame_id(trm, 'rsp_id', t.rsp_id, dbc)
			t.stat_id = trace_frame_id(trm, 'stat_id', t.stat_id, dbc)
			t.record_id = trace_frame_id(trm, 'record_id', t.record_id, dbc)
			t.dump_fc_id = trace_frame_id(trm, 'dump_fc_id', t.dump_fc_id, dbc)
		}
		t.level = (trm['level'] or { toml.Any(t.level) }).string()
		t.mode = (trm['mode'] or { toml.Any(t.mode) }).string()
		t.buffer_records = int((trm['buffer_records'] or { toml.Any(t.buffer_records) }).int())
		t.pre_pct = int((trm['pre_pct'] or { toml.Any(t.pre_pct) }).int())
		if pms := trm['push_ms'] {
			t.push_us = u64(pms.int()) * 1000
		}
		for k in ['cmd_id', 'rsp_id', 'stat_id', 'dump_fc_id', 'push_ms', 'pre_pct'] {
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

// trace_frame_id resolves a [trace] observability id: a literal number is the CAN id (used
// as-is — a colliding id is the author's problem); a string is a bus.dbc message name that must
// exist, and its id is used (so trace frames can piggyback on ids already defined in the DBC).
fn trace_frame_id(trm map[string]toml.Any, field string, def u32, dbc string) u32 {
	v := trm[field] or { return def }
	if v is string {
		db := candb.load_dbc_file(dbc) or {
			panic('loom2v: [trace] ${field} = "${v}" is a bus.dbc message name but ${os.file_name(dbc)} did not load: ${err}')
		}
		id := dbc_id_of(db, snake(v)) or {
			panic('loom2v: [trace] ${field} = "${v}" is not a message in ${os.file_name(dbc)}')
		}
		return u32(id)
	}
	// A literal id must be a legal CAN identifier — read as i64 (so a >32-bit value doesn't
	// wrap) and reject out-of-range before it becomes a bogus manifest frame.
	n := v.i64()
	if n < 0 || n > 0x1fff_ffff {
		panic('loom2v: [trace] ${field} ${n} is not a valid CAN id (0..0x1FFFFFFF)')
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
		// The exec-hook stream is raw records only: no TraceCmd/Rsp request path, no HandlerStat
		// heartbeat, no ISO-TP dump flow control. These keys have non-zero defaults but are inert
		// here, so an explicitly-set one (copied from a bare-metal trace block) would build while
		// silently doing nothing. Reject the explicit ones rather than ignore them.
		if m.trace.sw_keys.len > 0 {
			panic('loom2v: [target] kind="threadx" [trace] key(s) ${m.trace.sw_keys} are not implemented — ' +
				'the exec-hook stream has no TraceCmd/Rsp request path, HandlerStat heartbeat ' +
				'(push_ms/stat_id), ISO-TP dump flow control (dump_fc_id), or pre-trigger split ' +
				'(pre_pct); it streams only raw records on record_id — remove these keys for threadx builds')
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

// trace_manifest_frames: the observability frame ids blobly_net decodes natively. The ThreadX
// target streams ONLY raw records — advertise exactly what it sends.
fn trace_manifest_frames(m Model) []string {
	if !m.trace.on {
		return []string{}
	}
	tbus := if m.trace.bus != '' { m.trace.bus } else { m.telem.bus }
	return [
		'# trace frames: frame,id,bus',
		'record,0x${m.trace.record_id.hex()},${tbus}',
	]
}
