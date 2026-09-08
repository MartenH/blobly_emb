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
	partition_count int    // [[partition]] count; the module runner owns exactly one
	trace_bus_eth   bool   // the resolved trace bus is an eth bus
	has_bridge      bool   // external CAN signals, ISO-TP connections or routes
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
	if s.partition_count != 1 {
		return 'it declares ${s.partition_count} partitions — the module runner owns one schedule ' +
			'and one bus, so the per-core rings and the single dump owner are still ungenerated'
	}
	if s.trace_bus_eth {
		return 'its trace bus is eth — the dump runner speaks can.Channel'
	}
	if s.has_bridge {
		// NOT "a bridge owns the trace bus": the bridge may sit on a different bus entirely
		// (examples/trace_comm traces on can1 and bridges on can0). The conflict is the RUNNER —
		// the trace-host loop replaces the plain host run() that drives the bridge.
		return 'it has a COM bridge (external signals, ISO-TP or routes), and the trace-host ' +
			'runner replaces the plain run() that drives it — the two cannot coexist yet'
	}
	return ''
}
