module app

// An application component. This is the entire world an app developer sees:
// typed ports in/out and a handler the Loom calls on a schedule. No bus, no CAN
// id, no allocation. The Loom wires these ports to COM signals (generated later
// from config/ecu.toml).

// --- Typed ports (fixed-size value types) ---

pub struct VehicleSpeed {
pub mut:
	kph   u16
	valid bool
}

pub struct WarnLamp {
pub mut:
	on bool
}

// --- Component state ---

pub struct SpeedMonitor {
pub mut:
	over_limit bool
}

// on_10ms runs every 10 ms: read the speed port, drive the lamp port.
pub fn (mut c SpeedMonitor) on_10ms(speed VehicleSpeed, mut lamp WarnLamp) {
	c.over_limit = speed.valid && speed.kph > 120
	lamp.on = c.over_limit
}
