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
