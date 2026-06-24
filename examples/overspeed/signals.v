module main

// Signal value types for this example (no heap).
pub struct VehicleSpeed {
pub mut:
	kph   u16
	valid bool
}

pub struct EngineSpeed {
pub mut:
	rpm   u16
	valid bool
}

pub struct WarnLamp {
pub mut:
	on bool
}

pub struct FilteredSpeed {
pub mut:
	kph   u16
	valid bool
}

pub struct Overspeed {
pub mut:
	active bool
}

pub struct HighRev {
pub mut:
	active bool
}
