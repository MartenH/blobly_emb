module main

// @verifies REQ-TOPO-010
// The cross-core half of the route transport contract, on the pure checker (the generator
// panics with these exact messages via validate_route_cores). Same-core routes of both kinds
// stay legal; a cross-core FRAME route is a contract error (a raw PDU does not fit a signal
// cell — bulk's job); a cross-core SIGNAL route is the sanctioned crossing but rejected until
// the xioc lowering is generated, rather than emitting same-core code that only works where
// channels happen to be shareable.

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

fn test_cross_core_signal_route_rejected_until_lowered() {
	routes := [
		Route{
			from_bus:   'can0'
			from_frame: 'SrcFrame'
			to_bus:     'can1'
			signal:     'Speed'
			to_frame:   'DstFrame'
		},
	]
	msg := route_cores_error(routes, {
		'can0': 0
		'can1': 1
	}) or {
		assert false, 'a cross-core signal route must be rejected until the lowering exists'
		return
	}
	assert msg.contains('xioc lowering')
	assert msg.contains('REQ-TOPO-010')
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
