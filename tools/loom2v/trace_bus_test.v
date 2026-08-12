module main

// A bus can carry no signals at all and still need a partition: the comm thread is where the
// platform modules live, so a dedicated diagnostic bus has to be owned by somebody. Dropping it
// from the bridge set is what removed the trace bus from run() in examples/trace_comm and
// examples/trace_multicore (#191) — the ids stayed in ecu.toml and led nowhere.

fn test_a_signal_less_trace_bus_still_needs_an_owner() {
	m := Model{
		trace: TraceCfg{
			on:  true
			bus: 'can1'
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
		}
	}
	assert !bus_hosts_modules(m, 'can0', true)
}
