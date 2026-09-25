module main

import toml

// A bus can carry no signals at all and still need a partition: the comm thread is where the
// platform modules live, so a dedicated diagnostic bus has to be owned by somebody. Dropping it
// from the bridge set is what removed the trace bus from run() in examples/trace_comm and
// examples/trace_multicore (#191) — the ids stayed in ecu.toml and led nowhere.

fn test_a_signal_less_trace_bus_still_needs_an_owner() {
	m := Model{
		trace: TraceCfg{
			on:  true
			bus: 'can1'
			dump_fc_bound: true
		}
	}
	assert bus_hosts_modules(m, 'can1', false), 'the trace bus was left with nobody to own it'
	assert !bus_hosts_modules(m, 'can0', false), 'an unrelated bus must not gain a partition'
}

// [trace] with no bus of its own rides the telemetry bus — the same rule the manifest uses.
fn test_trace_falls_back_to_the_telemetry_bus() {
	m := Model{
		trace: TraceCfg{
			on: true
		}
		telem: TelemetryCfg{
			on:  true
			bus: 'can2'
		}
	}
	assert bus_hosts_modules(m, 'can2', false)
}

fn test_a_telemetry_only_bus_needs_an_owner() {
	m := Model{
		telem: TelemetryCfg{
			on:  true
			bus: 'can1'
		}
	}
	assert bus_hosts_modules(m, 'can1', false)
}

// Declared but switched off carries nothing, so it earns no partition.
fn test_disabled_blocks_host_nothing() {
	m := Model{
		trace: TraceCfg{
			bus: 'can1'
		}
		telem: TelemetryCfg{
			bus: 'can1'
		}
	}
	assert !bus_hosts_modules(m, 'can1', false)
}

// The single-partition host runner IS the owner of its trace bus. Giving that bus a bridge as
// well emitted a partition nothing spawns — dead code in the one example that always worked.
fn test_the_trace_host_runner_owns_its_bus_alone() {
	m := Model{
		trace: TraceCfg{
			on:  true
			bus: 'can0'
			dump_fc_bound: true
		}
	}
	assert !bus_hosts_modules(m, 'can0', true)
}

// A bare-metal/ThreadX target owns its bus from the superloop or the comm thread. Emitting a host
// bridge there is not merely redundant: the generated file imports osal only on the host path, so
// examples/h735_app ([telemetry] + [trace] on a signal-less bus) would not compile at all.
fn test_a_target_owns_its_bus_without_a_host_bridge() {
	m := Model{
		trace:  TraceCfg{
			on:  true
			bus: 'can0'
			dump_fc_bound: true
		}
		target: TargetCfg{
			on: true
		}
	}
	assert !bus_hosts_modules(m, 'can0', false)
}

// The module-host bridge is can.Channel/can.Frame with none of the things that normally pull in
// the CAN driver: a multi-partition host with [trace] on a CAN bus and telemetry OFF has no
// external signals, no ISO-TP and no routes. The import predicate missed exactly that shape, and
// the generated file did not compile. Both shipped examples have telemetry on, so neither caught
// it — this asserts the emitted header, not the helper.
fn test_a_trace_only_module_host_still_imports_the_can_driver() {
	mut m := Model{
		trace: TraceCfg{
			on:  true
			bus: 'can0'
			dump_fc_bound: true
		}
	}
	m.buses["can0"] = true
	_, glue := emit_module_headers(m, "ecu", false, false)
	assert glue.any(it.starts_with('import driver.can')), 'the generated file would not compile: ${glue}'
}

// --- the shape guard (#191) -------------------------------------------------------------------
// [trace] on a shape loom2v cannot generate used to WARN and build on, so `make all` succeeded and
// the example answered nothing on the bus. These pin the blocker down to ONE named condition each:
// the old message offered all three as a maybe, which is what made trace_multicore hard to diagnose.

fn test_the_supported_shape_has_no_blocker() {
	m := Model{
		trace: TraceCfg{
			on:  true
			bus: 'can0'
			dump_fc_bound: true
		}
		part: PartMap{
			by_part: {
				'app': []toml.Any{}
			}
		}
	}
	assert trace_shape_blocker(m, 'can0') == '', 'the single-partition host shape is generated'
}

// Two partitions ARE generated now (P3a: one dump owner plus one satellite core).
fn test_two_partitions_are_the_multicore_shape() {
	m := Model{
		trace: TraceCfg{
			on:  true
			bus: 'can0'
			dump_fc_bound: true
		}
		part:  PartMap{
			by_part: {
				'sense': []toml.Any{}
				'ctrl':  []toml.Any{}
			}
		}
	}
	assert trace_shape_blocker(m, 'can0') == '', 'the two-partition host shape is generated (P3a)'
}

// THREE is the ceiling, and not an oversight: TraceModule holds exactly one satellite import slot,
// so a third core's window has nowhere to be staged and would be silently missing from the dump.
fn test_a_third_partition_blocks_trace() {
	m := Model{
		trace: TraceCfg{
			on:  true
			bus: 'can0'
			dump_fc_bound: true
		}
		part:  PartMap{
			by_part: {
				'sense': []toml.Any{}
				'ctrl':  []toml.Any{}
				'aux':   []toml.Any{}
			}
		}
	}
	b := trace_shape_blocker(m, 'can0')
	assert b.contains('3 partitions'), 'the blocker must name the partition count, got: ${b}'
	assert b.contains('import slot'), 'it must say WHY three is refused, got: ${b}'
}

// P3c-0: the superloop is the single-core module runner, so one partition with no bridge is a
// generated shape — the blocker this replaced said "no module runner" for every bare-metal ECU.
fn test_the_baremetal_superloop_traces_one_partition() {
	m := Model{
		trace:  TraceCfg{
			on:    true
			bus:   'can0'
			level: 'fb'
		}
		telem:  TelemetryCfg{
			on:  true
			bus: 'can0'
		}
		target: TargetCfg{
			on: true
		}
		part:   PartMap{
			by_part: {
				'app': []toml.Any{}
			}
		}
	}
	assert trace_shape_blocker(m, 'can0') == ''
	assert baremetal_trace_on(m)
}

// ...but it has one loop and one core: a second partition is not a satellite it can import.
fn test_a_second_baremetal_partition_blocks_trace() {
	m := Model{
		trace:  TraceCfg{
			on:            true
			bus:           'can0'
			dump_fc_bound: true
		}
		target: TargetCfg{
			on: true
		}
		part:   PartMap{
			by_part: {
				'app':  []toml.Any{}
				'app2': []toml.Any{}
			}
		}
	}
	b := trace_shape_blocker(m, 'can0')
	assert b.contains('bare-metal') && b.contains('2'), b
}

// The superloop's own limits live in the SHARED policy (so syscheck sees them too): FB records
// only, one channel (the telemetry bus), and no heartbeat.
fn test_the_baremetal_superloop_refusals() {
	mut m := Model{
		trace:  TraceCfg{
			on:    true
			bus:   'can0'
			level: 'thread+fb'
		}
		telem:  TelemetryCfg{
			on:  true
			bus: 'can0'
		}
		target: TargetCfg{
			on: true
		}
		part:   PartMap{
			by_part: {
				'app': []toml.Any{}
			}
		}
	}
	assert trace_shape_blocker(m, 'can0').contains('"fb"')
	m.trace.level = 'fb'
	assert trace_shape_blocker(m, 'can0') == ''
	assert trace_shape_blocker(m, 'can1').contains('[telemetry] bus'), 'trace off the one channel'
	m.telem.on = false
	assert trace_shape_blocker(m, 'can0').contains('[telemetry] bus'), 'telemetry off: no channel'
	m.telem.on = true
	m.trace.sw_keys = ['push_ms']
	assert trace_shape_blocker(m, 'can0').contains('push_ms')
}

// The superloop's router must be id-width-exact (an extended frame sharing 0x7E2 is not a trace
// command), and the flow-control arm exists only when dump_fc is bound.
fn test_the_baremetal_router_is_width_exact() {
	mut m := Model{
		trace:  TraceCfg{
			on:     true
			cmd_id: 0x7E2
		}
		target: TargetCfg{
			on: true
		}
	}
	raw := baremetal_trace_bus(m).join('\n')
	assert raw.contains('if rx.ext {')
	assert raw.contains('u32(0x7e2) { g_tm.on_cmd(rx) }')
	assert !raw.contains('on_dump_fc')
	m.trace.dump_fc_bound = true
	assert baremetal_trace_bus(m).join('\n').contains('u32(0x7e6) { g_tm.on_dump_fc(t1, rx) }')
	// ThreadX is its own path: none of this is emitted there
	m.target.threadx = true
	assert baremetal_trace_bus(m) == []string{}
}

// The bridge conflict is about the RUNNER, not the bus: trace_comm traces on can1 and bridges on
// can0, and is still blocked. A message claiming the bridge "owns the trace bus" would be a lie.
fn test_a_bridge_on_another_bus_is_the_bridge_owner_shape() {
	// P3b: the bridge-owner runner drains the COM bus and serves the trace bus in one loop —
	// a bridge on ANOTHER bus (distinct core from the traced app) no longer blocks trace.
	m := Model{
		trace:       TraceCfg{
			on:  true
			bus: 'can1'
			dump_fc_bound: true
		}
		has_can_ext: true
		sig_of:      {
			'v': SigInfo{
				external: true
				bus:      'can0'
			}
		}
		bus_core:    {
			'can0': 0
			'can1': 0
		}
		part:        PartMap{
			by_part: {
				'app': []toml.Any{}
			}
			core_of: {
				'app': 1
			}
		}
	}
	assert trace_shape_blocker(m, 'can1') == ''
}

fn test_a_bridge_riding_the_trace_bus_blocks_trace() {
	// the same-bus piggyback (docs/trace-multicore.md §4.3) stays deferred: COM and the trace
	// handshake would share one channel's rx queue and tx window
	m := Model{
		trace:       TraceCfg{
			on:  true
			bus: 'can0'
			dump_fc_bound: true
		}
		has_can_ext: true
		sig_of:      {
			'v': SigInfo{
				external: true
				bus:      'can0'
			}
		}
		bus_core:    {
			'can0': 0
		}
		part:        PartMap{
			by_part: {
				'app': []toml.Any{}
			}
			core_of: {
				'app': 1
			}
		}
	}
	assert trace_shape_blocker(m, 'can0').contains('rides the trace bus'), 'got: ${trace_shape_blocker(m,
		'can0')}'
}

fn test_a_bridge_sharing_the_traced_apps_core_blocks_trace() {
	// the dump block header carries a CORE id: two traced entities on one core emit
	// indistinguishable blocks (#191 P3b)
	m := Model{
		trace:       TraceCfg{
			on:  true
			bus: 'can1'
			dump_fc_bound: true
		}
		has_can_ext: true
		sig_of:      {
			'v': SigInfo{
				external: true
				bus:      'can0'
			}
		}
		bus_core:    {
			'can0': 0
			'can1': 0
		}
		part:        PartMap{
			by_part: {
				'app': []toml.Any{}
			}
			core_of: {
				'app': 0 // same core as the bridge
			}
		}
	}
	assert trace_shape_blocker(m, 'can1').contains('shares a core'), 'got: ${trace_shape_blocker(m,
		'can1')}'
}

fn test_a_bridge_off_the_trace_bus_core_blocks_trace() {
	// the owner loop serves BOTH buses, so the bridge's core must be the trace bus's core —
	// a bridge elsewhere leaves the trace bus with no loop to serve it
	m := Model{
		trace:       TraceCfg{
			on:  true
			bus: 'can1'
			dump_fc_bound: true
		}
		has_can_ext: true
		sig_of:      {
			'v': SigInfo{
				external: true
				bus:      'can0'
			}
		}
		bus_core:    {
			'can0': 2
			'can1': 0
		}
		part:        PartMap{
			by_part: {
				'app': []toml.Any{}
			}
			core_of: {
				'app': 1
			}
		}
	}
	assert trace_shape_blocker(m, 'can1') != ''
}

// codex #282 r1: every runner speaks standard frames, so a 29-bit binding is refused at parse
// rather than silently ignored (cmd, dump_fc) or truncated on the wire (rsp, record).
fn test_an_extended_trace_binding_is_named() {
	mut t := TraceCfg{}
	assert trace_extended_binding(t) == '', 'the 0x7E2..0x7E6 defaults are standard'
	t.dump_fc_id = 0x18DA00F1
	assert trace_extended_binding(t) == 'dump_fc 0x18da00f1'
	t.rsp_id = 0x800
	assert trace_extended_binding(t).starts_with('rsp '), 'the first offender, in endpoint order'
}

// codex #282 r1: the module reports the traced partition's configured core, not a literal 0 —
// the manifest puts every handler on that core and a TraceCmd mask selects by it.
fn test_a_single_core_runner_reports_its_partitions_core() {
	m := Model{
		trace:  TraceCfg{
			on:    true
			level: 'fb'
		}
		target: TargetCfg{
			on: true
		}
		part:   PartMap{
			by_part: {
				'app': []toml.Any{}
			}
			core_of: {
				'app': 1
			}
		}
	}
	assert single_trace_core(m) == 1
	assert baremetal_trace_init(m).join('\n').contains('u32(0x7e5), 1, false,')
}

// codex #282 r1: LoadDetail is its own pending frame, retried every pass until the FIFO takes it —
// not a second send inside the CpuLoad block that a full FIFO drops for a whole period.
fn test_load_detail_is_retried_until_accepted() {
	p := TelemProducer{
		on:        true
		id:        0x7E0
		detail_id: 0x7E1
	}
	g := p.bus_tick(BusCtx{
		telem_active: true
		now:          't1'
		period:       'telem_period_us'
		gate:         ' && ch.tx_ready()'
		load:         ['\t\t\tload[0] = 1']
		det_ovr:      'sched.overruns()'
		det_lines:    ['\t\t\tdetail := [8]u8{}']
		frame:        'f'
		detframe:     'd'
		idx:          'i'
	}).join('\n')
	cpu_at := g.index('ch.send(f)') or { -1 }
	due_at := g.index('detail_due = true') or { -1 }
	retry_at := g.index('if detail_due && ch.tx_ready() {') or { -1 }
	assert cpu_at >= 0 && due_at > cpu_at && retry_at > due_at, g
	assert g.contains('last_overruns = ovr\n\t\t\t\tdetail_due = false'), 'cleared only on an accepted send'
}
