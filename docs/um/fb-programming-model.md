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
- `inp` is filled before the call and does not change while the handler runs. Each input is read
  whole, but two inputs from other threads are two separate reads: when values must belong
  together, make them one multi-field signal ([add-a-signal.md](add-a-signal.md)).
- `out` starts **zeroed on every dispatch** and every field in it is published after the call —
  an output you do not write this dispatch goes out as its zero value. Keep values you need across
  dispatches in the FB's own state.
- The only trigger is the period (`[[fb.handler]] period_ms`); the method name is free
  ([add-an-fb.md](add-an-fb.md)). No heap, no strings, bounded work ([../no-alloc.md](../no-alloc.md)).

## I want to ...

| ... | in `ecu.toml` | in the FB | host | ThreadX target |
|---|---|---|---|---|
| use another FB's value | `[[signal]] from = "<its partition>"`, `to = "<mine>"`; list it in `reads` | `inp.x.field` | ✅ | ✅ |
| give a value to another FB | the same signal, in my `writes` | `out.x.field = v` | ✅ | ✅ |
| send a value on CAN | `to = "can0"`; the signal name is the DBC signal; `[[frame]]` sets timing / E2E / SecOC | `out.x.field = v` (physical units) | ✅ | cyclic tx, plain u32 layouts, no E2E / SecOC yet |
| receive a value from CAN | `from = "can0"` | `inp.x.field` | ✅ | plain u32 layouts only |
| … and know if it is fresh | add `status = "RxStatus"`, and give its frame a deadline | `inp.x.status` | ✅ | not yet (R5) |
| drive an output pin | `to = "io"` + an `[[io.gpio]]` / `[[io.pwm]]` point of the same name | `out.led_green.on = true` | sim | ✅ |
| read an input pin / ADC | `from = "io"` + an `[[io.gpio]]` / `[[io.adc]]` point | `inp.pot_volt.count` | sim | ✅ |
| keep a value across power cycles | `persist = "now"` / `"shutdown"` on the signal, plus `[nvm]` and `[nm]` | read it and write it like any signal | builds, not stored | ✅ |
| report a fault (DTC) | `[[fault]]` naming my handler | `out.fault.x = .failed` / `.passed` | ✅ | not yet (R6) |

"sim" = the host's file-mirror stand-in for pins ([../io.md](../io.md)). The target limits are
the ThreadX comm thread's lean codec; generation names the exact rule when a config crosses one.

### Receive a value — and know whether to trust it

A signal received from a bus can carry `status = "RxStatus"`, filled by the platform:
`never_received` (nothing yet), `ok`, `timeout` or `integrity` (the newest frame failed its E2E or
SecOC check). **`timeout` needs a deadline on the frame** — `[[frame]] rx = { timeout_ms }`, or
`e2e = { ..., timeout_ms }` (required on a received E2E frame); without one a silent sender keeps
reading `ok` with its last value. An E2E frame can also carry a `lost` counter. The details are in
[../communication.md](../communication.md). **What each status means is your decision** — a
substitute value and a safety reaction are different responses:

```v
speed := if inp.vehicle_speed.status == .ok { inp.vehicle_speed.kph } else { fb.last_good }
```

Scaling is done before you see it: `kph` is km/h, whatever the DBC's factor and offset
([../application-model.md](../application-model.md)) — on the host; the target's lean codec takes
plain u32 layouts only (see the table).

### Send a value on CAN

Write the output; the bridge encodes it into its frame and sends it on the frame's schedule
(`cyclic` / on change / both — `[[frame]] tx`), adding the E2E counter + CRC or the SecOC MAC if
the frame is protected (host; see the table for the target). You never build a frame. See [add-a-signal.md](add-a-signal.md),
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

The platform restores it **before your first dispatch** (a fresh ECU, with nothing stored, starts
from the signal's zero value). `"now"` journals a change at most once per `[nvm] min_write_ms`
(default 1000 ms), so a power cut loses at most that window; `"shutdown"` is flushed only at bus
sleep. To keep a running total, read the signal and write it back:

```v
out.odo_meters.m = inp.odo_meters.m + delta   // reads = ["OdoMeters"], writes = ["OdoMeters"]
```

It needs `[nvm]` **and** `[nm]` (bus sleep is the flush point), a signal local to one thread with
one writer, and 1–2 unsigned fields; generation refuses anything else and checks flash wear
against the writing handler's period. On the host it builds with a warning and stores nothing.
See [../nvm.md](../nvm.md).

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

The handler must also `read` each `enable` signal, and the node needs its diagnostic server (one
`[[isotp]]`) with the cycle signal received on that bus; generation names whichever is missing.
Debouncing runs on your thread after the handler; the fault memory keeps the DTC's ISO 14229 status
(pending, confirmed, aging over operation cycles, in RAM for now) and a tester reads it with 0x19
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
