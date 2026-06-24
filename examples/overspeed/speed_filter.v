module main

// SpeedFilter (SENSE): smooths the raw bus speed.
// reads VehicleSpeed (CAN/COM) -> writes FilteredSpeed (local, same core).
pub struct SpeedFilter {
pub mut:
	last u16
}

pub fn (mut fb SpeedFilter) on_10ms(inp SpeedFilterIn, mut out SpeedFilterOut) {
	if inp.vehicle_speed.valid {
		// +2 rounds so the IIR converges to the input (not truncates below it)
		fb.last = u16((u32(fb.last) * 3 + inp.vehicle_speed.kph + 2) / 4)
	}
	out.filtered_speed = FilteredSpeed{
		kph:   fb.last
		valid: inp.vehicle_speed.valid
	}
}
