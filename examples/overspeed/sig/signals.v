module sig

// Signal value types for this example (hand-written, no heap).

// Bus signals (physical engineering units after COM scaling)
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

// Internal signals (FB -> FB)
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
