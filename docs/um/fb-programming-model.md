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

### Names

A name in config becomes a snake_case field in the FB: `EngineOverRev` is `out.fault.engine_over_rev`.
An acronym is a word of its own, so `ABSActive` is `abs_active` and `LED5State` is `led5_state`.

- **Names we own are PascalCase** (`[A-Z][A-Za-z0-9]*`, no `_`): FBs, signals no bus carries,
  faults and eth frames. That leaves one way to spell each of them. Partition and thread names
  are exempt: they never become FB fields.
- **Names a DBC owns keep the DBC's spelling.** That covers a bus signal (whose name *is* the
  DBC signal name) and CAN frames.
- **Generation refuses two names that give one field**, in every place a generated name lands:
  signals, FBs, buses, one FB's faults, one DBC's frames and frame signals.
  `AbsActive` next to `ABSActive` fails with both names quoted.
- **Names say what a value is, not where it comes from.** There is no `io_` or `can_` prefix,
  because an FB must not care whether `LedGreen` is a pin, a CAN frame or another FB. Moving it
  is a config change. Where a kind of port has different rules, it gets its own sub-struct
  instead (`out.fault.x`).

## I want to ...

| ... | in `ecu.toml` | in the FB | host | ThreadX target |
|---|---|---|---|---|
| use another FB's value | `[[signal]] from = "<its partition>"`, `to = "<mine>"`; list it in `reads` | `inp.x.field` | ✅ | ✅ — but not INTO a satellite core's partition yet (satellite → owner only) |
| give a value to another FB | the same signal, in my `writes` | `out.x.field = v` | ✅ | ✅ — but not INTO a satellite core's partition yet (satellite → owner only) |
| send a value on CAN | `to = "can0"`; the signal name is the DBC signal; `[[frame]]` sets timing / E2E / SecOC | `out.x.field = v` (physical units) | ✅ | cyclic tx, plain u32 layouts, no E2E / SecOC yet |
| receive a value from CAN | `from = "can0"` | `inp.x.field` | ✅ | plain u32 layouts only |
| … and know if it is fresh | add `status = "RxStatus"`, and give its frame a deadline | `inp.x.status` | ✅ | not yet (R5) |
| drive an output pin | `to = "io"` + an `[[io.gpio]]` / `[[io.pwm]]` point of the same name | `out.led_green.on = true` | sim | ✅ |
| read an input pin / ADC | `from = "io"` + an `[[io.gpio]]` / `[[io.adc]]` point | `inp.pot_volt.count` | sim | ✅ |
| keep a value across power cycles | `persist = "now"` / `"shutdown"` on the signal, plus `[nvm]` and `[nm]` | read it and write it like any signal | builds, not stored | ✅ |
| report a fault (DTC) | `[[fault]]` naming my handler | `out.fault.x = .failed` / `.passed` | ✅ | not yet (R6) |

"sim" = the host's file-mirror stand-in for pins ([../io.md](../io.md)). **The table shows the
common case, not every combination** — generation refuses one it cannot build and names the rule.
The ones you are most likely to meet: FBs on two *threads* of one partition cannot exchange a
signal yet (endpoints are partitions or buses — keep them on one thread, or use two partitions),
and an I/O point must be on the same core as the FB that reads or writes it ([../io.md](../io.md)).

### Receive a value — and know whether to trust it

A signal received from a bus can carry `status = "RxStatus"`, filled by the platform:
`never_received` (nothing yet), `ok`, `timeout` or `integrity` (the newest frame failed its SecOC
check — a wrong MAC, or a replayed / stale freshness value — or its E2E CRC; an E2E *repeat*, a stuck or replaying counter, publishes nothing, so such a
sender reaches `timeout` instead). **`timeout` needs a deadline on the frame** — `[[frame]] rx = { timeout_ms }`, or
`e2e = { ..., timeout_ms }` (required on a received E2E frame); without one a silent sender keeps
reading `ok` with its last value. An E2E frame can also carry a `lost` counter. The details are in
[../communication.md](../communication.md). **What each status means is your decision** — a
substitute value and a safety reaction are different responses. On `timeout` and `integrity` the
published value is **zero**, so a last good value has to live in the FB's own state:

```v
pub struct SpeedMonitor {
pub mut:
	last_good u16 // the newest trustworthy speed
	stale     u32 // activations we have been running on it (saturating)
}

pub fn (mut fb SpeedMonitor) on_10ms(inp ports.SpeedMonitorIn, mut out ports.SpeedMonitorOut) {
	match inp.vehicle_speed.status {
		.ok {
			// a good frame: use it, and remember it
			fb.last_good = inp.vehicle_speed.kph
			fb.stale = 0
			out.warn_lamp.on = fb.last_good > 120
		}
		.never_received {
			// start-up, nothing heard yet: no verdict — hold the safe default
			out.warn_lamp.on = false
		}
		.timeout {
			// the sender went quiet (the value is 0): ride on the last good value for a grace
			// period, then give up on it and fail safe
			// activations, not time: the Loom skips missed periods under overload, so 50 of them
			// is 500 ms of a 10 ms handler only when nothing overran
			if fb.stale < 50 {
				fb.stale++
			}
			out.warn_lamp.on = fb.stale >= 50 || fb.last_good > 120
		}
		.integrity {
			// the newest frame was corrupt or forged (the value is 0): never trust it, not even
			// for a grace period — fail safe now
			out.warn_lamp.on = true
		}
	}
}
```

`match` makes you handle all four: add a status later and the compiler asks where it goes. A
running example is `examples/overspeed`: `BrakeMonitor` reports the status it sees on a bus frame,
and `test/rxstatus.lua` walks it through `timeout`, `ok` and `integrity`. `never_received` exists
only in the first 300 ms after start, before any script of the suite runs — it is the enum's zero
value, pinned by a generator test and checked on the wire by hand (candump), not by the suite.

Scaling is done before you see it: `kph` is km/h, whatever the DBC's factor and offset — see
*Units and scaling* below for what the field type does to it.

### Units and scaling

An FB works in **physical units**; it never sees raw bits. The DBC's factor and offset are applied
at the bus, in the generated codec, both ways. Two things are yours to get right:

- **Receiving: the field type decides the precision.** The bridge converts raw → physical in
  `f64` and casts it to your field's type. `kph = "u16"` truncates 57.9 km/h to 57; for 0.1 km/h
  resolution declare `kph = "f32"`. A signal whose physical range goes negative (°C, a signed
  torque) needs a signed type (`i16`, `f32`) — a negative value cast into an unsigned field is
  meaningless.
- **Sending: rounded, not range-checked.** Your value is rounded to the nearest raw step
  (`(phys - offset) / factor`). The DBC's declared min/max are **not enforced**: a value outside
  them is encoded as is while it fits the signal's bit width (150 on an 8-bit `[0|100]` signal goes
  out as 150), and one that does not fit **wraps** into those bits. Clamp in the FB if your output
  can leave the declared range. Values pass through `f64` both ways, so an integer is exact only up
  to 2^53 — a 64-bit counter or identifier on the wire needs care.

Any other conversion — unit changes, clamping, filtering, rate limits — is ordinary FB code today;
declared transforms on a connection are planned, not built. On the ThreadX target the lean codec
does no scaling at all (plain u32 layouts, factor 1, offset 0 — see the table).

### Send a value on CAN

Write the output; the bridge encodes it into its frame and sends it on the frame's schedule
(`cyclic` / on change / both — `[[frame]] tx`), adding the E2E counter + CRC or the SecOC MAC if
the frame is protected (host; see the table for the target). You never build a frame. See [add-a-signal.md](add-a-signal.md),
[add-a-frame.md](add-a-frame.md).

### Protected frames (E2E, SecOC) — nothing to do in the FB

End-to-end protection and SecOC are declared on the **frame** and done by the bus bridge; the FB
reads and writes plain values either way:

```toml
[[frame]]
name  = "SecureFrame"
bus   = "can0"
secoc = { key = "10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f", data_id = 0x20, fresh_pos = 1, mac_pos = 2, mac_len = 4 }

[[frame]]
name = "BrakeStatus"
bus  = "can0"
e2e  = { data_id = 0x44, crc_pos = 4, counter_pos = 5, timeout_ms = 300 }
```

Sending, the bridge stamps the E2E counter and CRC, then SecOC's freshness and MAC. Receiving, it
verifies SecOC first, then E2E, and delivers the value only if both pass. What reaches the FB is the
verdict: `status` becomes `integrity` on a failed SecOC check (MAC or freshness / replay) or E2E CRC
(an E2E repeat is dropped, not flagged), `timeout` when E2E's own timeout runs out,
and `lost` counts the frames the sequence showed missing. The FB never sees a CRC, a counter, a
MAC or a key — it decides what a bad status means (a substitute value, a safe state). Host only
today; the keys are plain config, fine for test keys, not for production. See
[../communication.md](../communication.md).

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
persist = "now"          # survives a crash — or "shutdown": survives an ORDERLY shutdown only
```

The platform restores it **before your first dispatch** (a fresh ECU, with nothing stored, starts
from the signal's zero value). `"now"` survives a crash, losing at most the last write window;
`"shutdown"` survives an orderly shutdown only — after a crash it starts from zero. To keep a
running total, read the signal and write it back:

```v
out.odo_meters.m = inp.odo_meters.m + delta   // reads = ["OdoMeters"], writes = ["OdoMeters"]
```

It has prerequisites (`[nvm]` and `[nm]`, a one-writer thread-local signal, a small set of field
types) and a generation-time flash-wear check; a **target** build names whichever rule a config
breaks. A **host** build checks none of it — it warns, builds, and stores nothing — so validate a
persistence config by building for the target. The write pacing, the crash semantics and the wear
model are in [../nvm.md](../nvm.md).

### Report a fault (set a DTC)

Declare the fault, then write the **current** test result every dispatch:

```toml
[[fault]]
name     = "EngineOverRev"
dtc      = 0x021900
from     = "EngineMonitor.on_10ms"
debounce = { kind = "counter", fail = 3, pass = 3 }   # + inc / dec / jump: ../communication.md
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
no latch. The DTC's *history* — failed since the last clear, confirmed — is the fault memory's to
keep; your result is the current one, and it can pass again after the debounce's pass threshold
(neither debounce kind latches a failure). A self-latching FB would bring a cleared DTC straight
back. React to what you *detect*, not to what the fault memory recorded.
Host only today. See [../communication.md](../communication.md) and
[../diagnostics.md](../diagnostics.md) §3.3.

## What an FB never does

- Call a platform service. Sending, storing and raising a DTC are port fields plus config
  (above). Reading a clock and logging are **not available to an FB at all**: an FB can count
  its own activations, but that is not elapsed time — the Loom skips missed periods under
  overload rather than catching up — and there is no FB logging path.
- Read its own DTC status, or latch a fault itself.
- Know where a signal comes from — another FB, a bus, a pin or another core are all the same
  field ([../application-model.md](../application-model.md)).
- Allocate, block or wait.

## Not there yet

- **Parameters / variant coding** — a `[[param]]` read as an In field, written by a tester over a
  DID and persisted (rung R7, [../diagnostics.md](../diagnostics.md)).
- **Declared transforms** on a connection (clamp, unit conversion, rate limit) — for now, FB code.
- **Event-triggered handlers** (`on_<signal>_received`) and **queued events** (every occurrence,
  not the latest value) — [../autosar-comparison.md](../autosar-comparison.md).
- Faults on the target, freeze frames, and faults raised by a signal's receive status (R4c, R6).
