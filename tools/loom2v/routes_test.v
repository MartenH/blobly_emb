module main

// @verifies REQ-TOPO-010
// The cross-core half of the route transport contract, on the pure checker (the generator
// panics with these exact messages via validate_route_cores). Same-core routes of both kinds
// stay legal; a cross-core FRAME route is a contract error (a raw PDU does not fit a signal
// cell — bulk's job); a cross-core SIGNAL route is the sanctioned crossing — its f64 rides
// the IOC channel cfg2v allocates (xr_ch is the cfg2v/loom2v naming contract), the source
// bridge publishes on rx, the destination bridge composes and transmits on its own channel.
// End-to-end proof: examples/gw_xcore on two vcans.

fn test_same_core_routes_pass() {
	routes := [
		Route{
			from_bus:   'can0'
			from_frame: 'WheelSpeeds'
			to_bus:     'can1'
		},
		Route{
			from_bus:   'can0'
			from_frame: 'SrcFrame'
			to_bus:     'can1'
			signal:     'Speed'
			to_frame:   'DstFrame'
		},
	]
	if _ := route_cores_error(routes, {
		'can0': 0
		'can1': 0
	})
	{
		assert false, 'same-core routes must not be rejected'
	}
}

fn test_cross_core_frame_route_is_a_contract_error() {
	routes := [
		Route{
			from_bus:   'can0'
			from_frame: 'WheelSpeeds'
			to_bus:     'can1'
		},
	]
	msg := route_cores_error(routes, {
		'can0': 0
		'can1': 1
	}) or {
		assert false, 'a cross-core frame route must be rejected'
		return
	}
	assert msg.contains('does not fit a signal cell')
	assert msg.contains('REQ-TOPO-010')
	assert msg.contains('bulk-transport.md') // the error must say where frame routing IS headed
}

fn test_cross_core_signal_route_is_the_sanctioned_crossing() {
	r := Route{
		from_bus:   'can0'
		from_frame: 'SrcFrame'
		to_bus:     'can1'
		signal:     'Speed'
		to_frame:   'DstFrame'
	}
	cores := {
		'can0': 0
		'can1': 1
	}
	if _ := route_cores_error([r], cores) {
		assert false, 'a cross-core SIGNAL route is sanctioned (REQ-TOPO-010) and must pass'
	}
	assert r.crossing(cores)
	assert !r.crossing({
		'can0': 0
		'can1': 0
	})
	// the channel const name is the cfg2v/loom2v contract — both emit against it
	assert r.xr_ch() == 'xr_can1_dst_frame_speed_ch'
}

fn test_unlisted_bus_defaults_to_core_zero() {
	// a bus absent from bus_core (host single-core configs) counts as core 0 — no false reject
	routes := [
		Route{
			from_bus:   'can0'
			from_frame: 'F'
			to_bus:     'can1'
		},
	]
	if _ := route_cores_error(routes, {
		'can0': 0
	})
	{
		assert false, 'an unlisted bus is core 0 and must not trip the cross-core check'
	}
}
