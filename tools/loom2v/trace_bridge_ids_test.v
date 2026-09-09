module main

import toml

// The bridge owner stamps its thread spans with host_comm_tid (the capture's id_base), and
// emit_manifest writes the comm_<bb> row the host resolves them through. They are computed in
// two places, so they are pinned against each other here: a lane whose id does not match its
// row is an unlabelled swimlane, which is the whole complaint of #191.

fn bridge_model() Model {
	return Model{
		trace: TraceCfg{
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
			by_part:     {
				'app': []toml.Any{}
			}
			core_of:     {
				'app': 1
			}
			threads_of:  {
				'app': ['app_main']
			}
			thread_prio: {
				'app_main': 10
			}
		}
	}
}

fn test_the_owner_lane_id_is_its_manifest_row() {
	m := bridge_model()
	assert trace_shape_blocker(m, 'can1') == '', 'precondition: the bridge-owner shape'
	tid := host_comm_tid(m)
	assert tid == 2, 'one app thread takes id 1, the bridge follows it — got ${tid}'
}

// The HOST io row is written AFTER the bridge rows in emit_manifest (only the ThreadX path puts
// io ahead of them), so io must NOT shift the bridge lane — a shift stamped the owner's spans
// with the io thread's id, and this test asserted the shifted value, pinning the bug in place
// until the self-review on #191 caught both.
fn test_the_host_io_thread_does_not_shift_the_owner_lane() {
	mut m := bridge_model()
	m.io_points = [IoPoint{}]
	assert host_comm_tid(m) == 2
}

// Two app threads push the bridge lane to 3: the rows are app threads first, in declaration
// order, then the bridges.
fn test_a_second_app_thread_shifts_the_owner_lane() {
	mut m := bridge_model()
	m.part.threads_of['app'] = ['app_main', 'app_aux']
	assert host_comm_tid(m) == 3
}

// A same-core route is composed and sent by its SOURCE loop, which takes the destination channel
// as a parameter — it is not a second bridge thread, and counting it as one refused a valid
// single-owner shape (codex #274 r2).
fn test_a_same_core_route_is_one_bridge_loop() {
	mut m := bridge_model()
	m.sig_of = map[string]SigInfo{}
	m.bus_core = {
		'can0': 0
		'can2': 0
		'can1': 0
	}
	m.routes = [Route{
		from_bus: 'can0'
		to_bus:   'can2'
		signal:   'VehicleSpeed'
	}]
	assert bridge_can_buses(m) == ['can0'], 'got ${bridge_can_buses(m)}'
	assert trace_shape_blocker(m, 'can1') == '', 'got: ${trace_shape_blocker(m, 'can1')}'
}

// ...but a route whose destination CROSSES cores does get its own loop, and two loops is a
// second traced lane the runner has no ring for.
fn test_a_crossing_route_is_two_bridge_loops() {
	mut m := bridge_model()
	m.sig_of = map[string]SigInfo{}
	m.bus_core = {
		'can0': 0
		'can2': 1
		'can1': 0
	}
	m.routes = [Route{
		from_bus: 'can0'
		to_bus:   'can2'
		signal:   'VehicleSpeed'
	}]
	assert trace_shape_blocker(m, 'can1').contains('COM bridge buses')
}

// A same-core route that TARGETS the trace bus is still refused: it is not a second loop, but
// COM frames would share the channel with the trace handshake (the same-bus piggyback).
fn test_a_route_onto_the_trace_bus_is_refused() {
	mut m := bridge_model()
	m.sig_of = map[string]SigInfo{}
	m.bus_core = {
		'can0': 0
		'can1': 0
	}
	m.routes = [Route{
		from_bus: 'can0'
		to_bus:   'can1' // the trace bus
		signal:   'VehicleSpeed'
	}]
	assert trace_shape_blocker(m, 'can1').contains('rides the trace bus')
}
