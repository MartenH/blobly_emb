# Application model — Software Units (SUs)

How application developers write code in blobly_emb. This is a **proposal** for
the developer-facing model; the open choices are flagged at the end.

## The golden rule

> A **Software Unit (SU)** is a pure function of its **input signals** to its
> **output signals**, plus private state. It knows nothing about buses, cores,
> IOC, the other SUs, or where its signals come from. It never allocates.

Everything else — routing a signal between SUs or to/from a bus, choosing a
transport, scaling raw bus values — happens **around** the SU, in generated glue
and config. That's what makes an SU trivially testable and portable.

(The config today calls these `[[component]]`; we'll converge the name to **SU**.)

## Anatomy of an SU

- **State**: a value struct, private to the SU (no heap).
- **Handlers**: methods the Loom calls. `on_init` once at startup; `on_<period>`
  periodically (e.g. `on_10ms`); later, event handlers (`on_<signal>_received`).
- **Signals**: typed values it reads (inputs) and writes (outputs). A signal type
  is an app-defined value struct (e.g. `VehicleSpeed { kph u16; valid bool }`).

## Reading & writing signals (proposed)

An SU's handler receives a generated **Inputs** snapshot and a **Outputs** struct;
it reads/writes them as plain fields. The Loom snapshots all inputs before the
call and publishes all outputs after — so the handler sees a coherent snapshot
and stays a pure transform.

```v
// app/speed_monitor.v — written by the developer
module app
import sig

pub struct SpeedMonitor {  // private state only
pub mut:
	over_limit bool
}

pub fn (mut su SpeedMonitor) on_10ms(in sig.SpeedMonitorIn, mut out sig.SpeedMonitorOut) {
	su.over_limit = in.vehicle_speed.valid && in.vehicle_speed.kph > 120
	out.warn_lamp.on = su.over_limit
}
```

```v
// sig/speedmonitor_ports.v — GENERATED from ecu.toml (do not edit)
module sig

pub struct SpeedMonitorIn {
pub mut:
	vehicle_speed VehicleSpeed
}
pub struct SpeedMonitorOut {
pub mut:
	warn_lamp WarnLamp
}
```

```v
// gen/loom_gen.v — GENERATED glue (do not edit)
fn handler_app_speed_monitor_on_10ms(ctx voidptr) {
	mut st := unsafe { &Partition_app_state(ctx) }
	mut inp := sig.SpeedMonitorIn{}
	osal.ioc_acquire2(vehicle_speed_ch, &inp.vehicle_speed, u8(sizeof(inp.vehicle_speed)))
	mut outp := sig.SpeedMonitorOut{}
	st.speed_monitor.on_10ms(inp, mut outp)
	osal.ioc_publish2(warn_lamp_ch, &outp.warn_lamp, u8(sizeof(outp.warn_lamp)))
}
```

Why grouped `In`/`Out` structs (not positional params): adding a signal is a
config change + a new field — **the handler signature never changes**, and an SU
with many signals stays readable. Field access (`in.vehicle_speed`) is as easy as
it gets.

### Module layering (avoids an import cycle)

- **`sig/`** — signal value types + generated `*In`/`*Out` port structs. Depends
  on nothing.
- **`app/`** — the SUs. Imports `sig`.
- **`gen/`** — the generated Loom glue. Imports `app` + `sig`. Nothing imports
  `gen` that `gen` imports back.

So the SU references only `sig` (never `gen`), while `gen` calls into `app`. No
cycle, ergonomic API.

## Communication topology — all transparent to the SU

The SU always just reads/writes a named signal. **Where** that signal lives is
config, resolved in the generated glue:

| Signal connects… | Generated glue uses | SU code |
|---|---|---|
| SU → SU, same partition | a local cell (direct memory, no sync) | identical |
| SU → SU, different cores | IOC channel (transport per `[[ioc]]`) | identical |
| SU ↔ communication bus | COM codec + driver (CAN/LIN/…) | identical |

Because the SU code is identical in all three cases, you can move an SU to
another core, or re-source a signal from the bus instead of another SU, **without
touching the SU** — only `ecu.toml` changes.

## Scaling & transformers — at the boundary, never in the SU

**Decision: SUs work in physical engineering units; raw↔physical scaling lives at
the communication boundary (COM), and any other transform is a declared,
generated step on the connection — not hand-written in the SU.**

- **Bus scaling (raw ↔ physical)** is the DBC `factor`/`offset`. It's applied in
  the generated COM codec (`dbc2cfg` already emits `*_phys()`), so a signal read
  from CAN arrives at the SU already in km/h, °C, etc. The SU never sees raw bits.
- **Other transforms** (unit conversion, range clamping, end-to-end protection,
  rate limiting) are **declared on the signal/connection** in config and emitted
  into the generated path. They run where the signal crosses a boundary
  (producer→IOC, or COM↔bus), so every consumer sees the transformed value and
  the SU stays a pure function.

Rationale: keep SUs free of representation concerns so they're portable across
ECUs and bus matrices, testable with plain physical values, and unaffected when a
DBC scaling or a transform changes.

Example (proposed config; transforms optional):

```toml
[[ioc]]
name = "VehicleSpeed"   # physical km/h after COM scaling
from = "io"             # COM/driver side
to   = "app"
# transform = "clamp:0..350"   # optional, generated; SU still just reads km/h
```

## Signal validity

A signal carries validity: an IOC channel never written reads back as
"no value yet" (the accessor returns the zero value with `valid = false`, by
convention a `valid` field or a separate freshness flag). SUs must handle
"not yet received" (as `SpeedMonitor` does with `in.vehicle_speed.valid`).

## Worked example — SU → SU chaining

A filter SU sits between the bus and the monitor. Note `SpeedMonitor` is
**unchanged** — it doesn't know its input now comes from another SU instead of the
bus.

```v
// app/speed_filter.v
pub struct SpeedFilter {
pub mut:
	last u16
}
pub fn (mut su SpeedFilter) on_10ms(in sig.SpeedFilterIn, mut out sig.SpeedFilterOut) {
	// simple IIR; reads raw bus speed, writes a filtered signal
	su.last = (su.last * 3 + in.vehicle_speed_raw.kph) / 4
	out.vehicle_speed = sig.VehicleSpeed{ kph: su.last, valid: in.vehicle_speed_raw.valid }
}
```

```toml
# ecu.toml: chain bus -> SpeedFilter -> SpeedMonitor
[[ioc]]
name = "VehicleSpeedRaw"; from = "io";  to = "app"; transport = "double"
[[ioc]]
name = "VehicleSpeed";    from = "app"; to = "app"; transport = "double"  # SU->SU
[[ioc]]
name = "WarnLamp";        from = "app"; to = "io";  transport = "double"

[[component]]
name = "SpeedFilter"; partition = "app"
  [[component.handler]]
  name = "on_10ms"; period_ms = 10; reads = ["VehicleSpeedRaw"]; writes = ["VehicleSpeed"]

[[component]]
name = "SpeedMonitor"; partition = "app"
  [[component.handler]]
  name = "on_10ms"; period_ms = 10; reads = ["VehicleSpeed"]; writes = ["WarnLamp"]
```

The Loom generates both SUs' glue and schedules them in dependency order on the
partition. Re-sourcing `VehicleSpeed` from the bus instead of `SpeedFilter` is a
one-line config edit; neither SU changes.

## Implemented today vs. proposed here

- **Implemented**: SUs as state + handler; positional signal params; the Loom glue
  generated by `loom2v`; scaling at the COM boundary (`dbc2cfg` `*_phys`).
- **Proposed by this doc**: grouped `In`/`Out` port structs in a `sig` module
  (stable signatures, field access); SU↔SU local routing; declared transforms;
  the `SU` name. These are small evolutions of what exists.

## Open choices (please confirm)

1. **Read/write API**: grouped `In`/`Out` structs (this doc) vs. the current
   positional params vs. explicit accessor methods (`p.vehicle_speed()`).
2. **Scaling/transforms location**: at the COM/connection boundary (this doc) vs.
   allowing transforms inside SUs.
3. **Naming**: rename `component` → `SU` across config/docs/code.
