module ecumodel

// The ONE definition of "can loom2v generate [trace] for this ECU?".
//
// loom2v emits the host trace runner (comm/trace's TraceModule driven by the module runner) for the
// single-partition host shape only; the ThreadX target has its own exec-hook stream instead. The
// predicate used to exist three times — loom2v's `trace_host`, loom2v's panic message, and
// sysmodel's `trace_generated` — which is how syscheck and loom2v came to disagree about the eth
// trace bus, and how the panic could have printed an empty reason had one copy gained a condition.
// It lives here because loom2v and sysmodel both import ecumodel but hold different model types:
// the inputs below are the plain values each can supply.

// TraceShape is what the policy needs to know about an ECU. Callers handle `threadx` themselves
// (it selects a different generator, not a failure) before consulting the blocker.
pub struct TraceShape {
pub:
	threadx         bool   // [target] kind = "threadx": the exec-hook stream, not the host runner
	baremetal       bool   // a target that is not ThreadX: the inline superloop
	partition_count int    // [[partition]] count; the host runners cover one or two
	trace_bus_eth   bool   // the resolved trace bus is an eth bus
	has_bridge      bool   // external CAN signals, ISO-TP connections or routes
	// P3b (the bridge-owner runner) relaxed the blanket bridge blocker to these two:
	bridge_on_trace_bus bool // some bridge work rides the trace bus itself (same-bus piggyback)
	bridge_core_clash   bool // a bridge shares its core with a traced app partition
	bridge_off_trace_core bool // a bridge sits on a core other than the trace bus's
	bridge_count        int  // distinct CAN buses with bridge work; the owner loop drains one
	multi_lane          bool // two traced entities (owner + satellite): P3a's two cores, or P3b
	dump_fc_bound       bool // [trace].dump_fc is bound -> the ISO-TP block dump
}

// trace_shape_blocker names the ONE reason [trace] cannot be generated on this shape, or '' when it
// can. Callers panic on a non-empty return: a config that asks for trace and silently gets none
// looks identical to a working one until nothing answers on the bus (#191). Naming the single
// tripped condition matters — the message this replaced listed every condition as a maybe.
pub fn trace_shape_blocker(s TraceShape) string {
	if s.threadx {
		// Not a defect: ThreadX generates the raw exec-hook stream through its own path. Callers
		// take that branch first, so this string is a guard against a caller that forgets to.
		return 'the ThreadX target streams the exec hooks, not the host module runner'
	}
	if s.baremetal {
		return 'the bare-metal superloop target has no module runner'
	}
	if s.partition_count < 1 || s.partition_count > 2 {
		// One partition is the single-core host runner; two is P3a's multi-core runner (one dump
		// owner plus one satellite). Three is the ceiling, not an oversight: TraceModule holds
		// exactly ONE satellite import slot (set_remote), so a third core's window has nowhere to
		// be staged and would be silently absent from the dump.
		return 'it declares ${s.partition_count} partitions — the host trace runners cover one ' +
			'(single-core) or two (one dump owner plus one satellite core); a third core has no ' +
			'import slot in the module and its window would simply never be dumped'
	}
	if s.trace_bus_eth {
		return 'its trace bus is eth — the dump runner speaks can.Channel'
	}
	if s.has_bridge {
		// P3b: the bridge-owner runner — ONE loop drains the COM bus, records its own drain
		// spans (note_thread) and serves the TraceModule on the trace bus — covers the
		// different-bus shape (examples/trace_comm: bridge on can0, trace on can1). What it
		// cannot cover, most specific first, so the message names the blocker a config would
		// actually hit next:
		if s.bridge_on_trace_bus {
			// the trace handshake and COM would share one channel's rx queue and tx window —
			// the same-bus piggyback docs/trace-multicore.md §4.3 defers.
			return 'its COM bridge rides the trace bus itself — the same-bus piggyback is not ' +
				'generated yet (docs/trace-multicore.md §4.3); give trace a dedicated bus'
		}
		if s.bridge_count > 1 {
			// one owner loop drains ONE com bus; a second bridge would need its own thread,
			// whose spans have no ring (one traced entity per core, one ring per entity).
			return 'it has ${s.bridge_count} COM bridge buses — the bridge-owner trace runner ' +
				'drains one; a second bridge thread would have no traced lane'
		}
		if s.bridge_off_trace_core {
			// the owner loop serves BOTH buses from one core; a bridge elsewhere would leave
			// the trace bus with no loop to drain it.
			return 'its COM bridge does not run on the trace bus\'s core — the bridge-owner ' +
				'runner serves both from one loop, so give them the same core'
		}
		if s.bridge_core_clash {
			// the dump block header carries a CORE id: two traced entities on one core emit
			// indistinguishable blocks (#191 P3b design note).
			return 'its COM bridge shares a core with a traced app partition — the dump block ' +
				'header carries a core id, so two traced entities on one core emit ' +
				'indistinguishable blocks; give them distinct cores'
		}
		if s.partition_count != 1 {
			// the module holds one satellite import slot, and the bridge-owner already IS the
			// owner entity — one app partition (the satellite) is the ceiling.
			return 'it has a COM bridge and ${s.partition_count} app partitions — the ' +
				'bridge-owner runner traces the bridge plus ONE app partition (the module ' +
				'holds one satellite import slot)'
		}
	}
	// LAST, and not bridge-specific: it applies to P3a's two cores as much as to P3b. A shape
	// blocked above is told THAT first — binding dump_fc would not have helped it.
	if s.multi_lane && !s.dump_fc_bound {
		// A multi-lane dump is TWO windows, and only the ISO-TP block path carries them: it
		// prefixes each block with (core, count, more), while the raw record stream is bare
		// 8-byte records that say nothing about whose ring they came from — and produce()'s raw
		// branch streams the owner's ring only, so the satellite's window would simply never
		// leave (#191 P3b; the same trap on P3a). Bind [trace].dump_fc and it is the block path.
		return 'it traces two lanes with no [trace].dump_fc — the raw record stream carries ' +
			'one window with no core header, so the second lane would be dumped nowhere; bind ' +
			'dump_fc (the ISO-TP flow-control id) for a multi-lane trace'
	}
	return ''
}
