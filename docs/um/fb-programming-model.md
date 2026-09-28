# How do I ... from inside an FB? — the programming model

Everything an application developer does happens in two places: a handler method in `app/`, and
a few lines of `ecu.toml`. There is **no service API** — no `send()`, no `nvm_write()`, no
`set_dtc()`, no clock. An FB reads its **In** port, writes its **Out** port, and the config says
what those ports are connected to. This page is the FB's view of every such connection; the linked
docs hold the design behind each.

## The contract

```v
module app

import ports

pub struct EngineMonitor { // private state: plain fields, no heap
pub mut:
	high bool
}

pub fn (mut fb EngineMonitor) on_10ms(inp ports.EngineMonitorIn, mut out ports.EngineMonitorOut) {
	fb.high = inp.engine_speed.status == .ok && inp.engine_speed.rpm > 4000
	out.high_rev.active = fb.high
}
```

- A handler always takes exactly `(inp, mut out)`; every signal in its `reads` / `writes` is a
  field of those generated structs (`ports/ports_gen.v`, annotated with where each comes from).
- `inp` is a coherent snapshot taken before the call; nothing changes while the handler runs.
- `out` starts **zeroed on every dispatch** and every field in it is published after the call —
  an output you do not write this dispatch goes out as its zero value. Keep values you need across
  dispatches in the FB's own state.
- The only trigger is the period (`[[fb.handler]] period_ms`); the method name is free
  ([add-an-fb.md](add-an-fb.md)). No heap, no strings, bounded work ([../no-alloc.md](../no-alloc.md)).

## I want to ...

| ... | in `ecu.toml` | in the FB |
|---|---|---|
| use another FB's value | `[[signal]] from = "<its partition>"`, `to = "<mine>"`; list it in `reads` | `inp.x.field` |
| give a value to another FB | the same signal, in my `writes` | `out.x.field = v` |
| send a value on CAN | `to = "can0"`; the signal name is the DBC signal; `[[frame]]` sets timing / E2E / SecOC | `out.x.field = v` (physical units) |
| receive a value from CAN | `from = "can0"`; add `status = "RxStatus"` to its fields | `inp.x.field`, `inp.x.status` |
| drive an output pin | `to = "io"` + an `[[io.gpio]]` / `[[io.pwm]]` point of the same name | `out.led.on = true` |
| read an input pin / ADC | `from = "io"` + an `[[io.gpio]]` / `[[io.adc]]` point | `inp.pot_volt.count` |
| keep a value across power cycles | `persist = "now"` or `"shutdown"` on the signal | read it and write it like any signal |
| report a fault (DTC) | `[[fault]]` naming my handler | `out.fault.x = .failed` / `.passed` |

### Receive a value — and know whether to trust it

A signal received from a bus can carry `status = "RxStatus"`, filled by the platform:
`never_received` (the zero value — nothing yet), `ok`, `timeout` (the sender went quiet) or
`integrity` (the newest frame failed its E2E or SecOC check; the value is then zero). An E2E frame
can also carry `lost`, a running count of frames that never arrived intact. **What each status
means is your decision** — a substitute value and a safety reaction are different responses:

```v
speed := if inp.vehicle_speed.status == .ok { inp.vehicle_speed.kph } else { fb.last_good }
```

Scaling is done before you see it: `kph` is km/h, whatever the DBC's factor and offset
([../application-model.md](../application-model.md)). Details: [../communication.md](../communication.md).

### Send a value on CAN

Write the output; the bridge encodes it into its frame and sends it on the frame's schedule
(`cyclic` / on change / both — `[[frame]] tx`), adding the E2E counter + CRC or the SecOC MAC if
the frame is protected. You never build a frame. See [add-a-signal.md](add-a-signal.md),
[add-a-frame.md](add-a-frame.md).

### Drive or read a pin

An IO point is just another endpoint: `to = "io"` for an output an FB writes, `from = "io"` for an
input the platform samples. The pin, the timer and the ADC live in config and the board layer:

```toml
[[signal]]
name   = "LedGreen"
fields = { on = "bool" }
from   = "ctrl"
to     = "io"

[[io.gpio]]
name      = "LedGreen"
pin       = "PB0"
period_ms = 10
init      = false        # outputs: the pin state before the first write
```

```v
out.led_green.on = inp.user_button.pressed
```

Exactly one handler may write an output pin; types are fixed per kind (gpio `bool`, adc / pwm
`u16`/`u32`, pwm in permille). See [../io.md](../io.md).

### Keep a value across power cycles

Mark the signal persistent — the FB cannot tell it is:

```toml
[[signal]]
name    = "OdoMeters"
fields  = { m = "u32" }
from    = "app"
to      = "app"
persist = "now"          # journaled on write (crash-safe) — or "shutdown": flushed at bus sleep
```

The platform restores it **before your first dispatch** (a fresh ECU sees the declared default)
and journals every change. To keep a running total, read the signal and write it back:

```v
out.odo_meters.m = inp.odo_meters.m + delta   // reads = ["OdoMeters"], writes = ["OdoMeters"]
```

Today this runs on the ThreadX target (`[nvm]`); the host has no journal. Wear is checked at
generation against the writing handler's period. See [../nvm.md](../nvm.md).

### Report a fault (set a DTC)

Declare the fault, then write the **current** test result every dispatch:

```toml
[[fault]]
name     = "EngineOverRev"
dtc      = 0x021900
from     = "EngineMonitor.on_10ms"
debounce = { kind = "counter", fail = 3, pass = 3 }
enable   = ["IgnitionOn.on"]

[fault_memory]
cycle = "IgnitionOn.on"
```

```v
out.fault.engine_over_rev = if inp.engine_speed.status != .ok {
	.not_tested // no trustworthy input: no verdict (also the zero value)
} else if inp.engine_speed.rpm > 6000 {
	.failed
} else {
	.passed
}
```

That is all. Debouncing runs on your thread after the handler; the fault memory keeps the DTC's
ISO 14229 status (pending, confirmed, aging over operation cycles) and a tester reads it with 0x19
and clears it with 0x14. **Reporting is one-way:** you never read your DTC's status, and you keep
no latch — "failed once, stay failed" is debounce config, and a self-latching FB would bring a
cleared DTC straight back. React to what you *detect*, not to what the fault memory recorded.
Host only today. See [../communication.md](../communication.md) and
[../diagnostics.md](../diagnostics.md) §3.3.

## What an FB never does

- Call a platform service — send, store, log, read a clock, raise a DTC. Every one of those is a
  port field plus config.
- Read its own DTC status, or latch a fault itself.
- Know where a signal comes from — another FB, a bus, a pin or another core are all the same
  field ([../application-model.md](../application-model.md)).
- Allocate, block or wait.

## Not there yet

- **Parameters / variant coding** — a `[[param]]` read as an In field, written by a tester over a
  DID and persisted (rung R7, [../diagnostics.md](../diagnostics.md)).
- **Event-triggered handlers** (`on_<signal>_received`) and **queued events** (every occurrence,
  not the latest value) — [../autosar-comparison.md](../autosar-comparison.md).
- Faults on the target, freeze frames, and faults raised by a signal's receive status (R4c, R6).
