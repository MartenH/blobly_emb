# Application model — Function Blocks (FB)

How application developers write code in blobly_emb.

> A **Function Block (FB)** is a unit of application logic with typed **input
> signals**, typed **output signals**, and private state, that runs on a
> schedule. (Term from IEC 61131-3 control engineering — *not* AUTOSAR. It names
> exactly this shape and composes natively.)

## The golden rule

> An FB is a **pure function of its input signals to its output signals**, plus
> private state. It knows nothing about buses, cores, IOC, the other FBs, or where
> its signals come from. It never allocates.

Everything else — routing a signal between FBs or to/from a bus, choosing a
transport, scaling raw bus values — happens **around** the FB, in generated glue
and config. That's what makes an FB trivially testable and portable.

## Anatomy of an FB

- **State**: a value struct, private to the FB (no heap).
- **Handlers**: methods the Loom calls. `on_init` once at startup; `on_<period>`
  periodically (e.g. `on_10ms`); later, event handlers (`on_<signal>_received`).
- **Signals**: typed values it reads (inputs) and writes (outputs). A signal type
  is a value struct (e.g. `VehicleSpeed { kph u16; valid bool }`).

FBs compose: a *composite* FB is wired from smaller FBs in config; the developer
writes only *leaf* FBs (logic) and the wiring (`ecu.toml`).

## Reading & writing signals

An FB's handler receives a generated **Inputs** snapshot and an **Outputs**
struct; it reads/writes them as plain fields. The Loom snapshots all inputs before
the call and publishes all outputs after — coherent snapshot, pure transform.

```v
// app/speed_monitor.v — written by the developer
module app
import sig

pub struct SpeedMonitor {  // private state only
pub mut:
	over_limit bool
}

pub fn (mut fb SpeedMonitor) on_10ms(inp sig.SpeedMonitorIn, mut out sig.SpeedMonitorOut) {
	fb.over_limit = inp.vehicle_speed.valid && inp.vehicle_speed.kph > 120
	out.warn_lamp.on = fb.over_limit
}
// (parameter is `inp`, not `in` — `in` is a V keyword)
```

```v
// sig/speedmonitor_ports.v — GENERATED from ecu.toml (do not edit)
module sig

pub struct SpeedMonitorIn {
pub mut:
	// signal "VehicleSpeed" — physical km/h
	//   from: CAN can0 / DBC Powertrain.VehicleSpeed  frame 0x100  bits 16|12 (x0.1)
	//   path: COM -> IOC(double) -> app
	vehicle_speed VehicleSpeed
}
pub struct SpeedMonitorOut {
pub mut:
	// signal "WarnLamp" -> CAN can0 / LampFrame 0x101 (bit 0)
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
config change + a new (annotated) field — **the handler signature never changes**,
and an FB with many signals stays readable. Field access is as easy as it gets.

### One example = one module

Each example (`examples/<name>/`) is a single `module main`: the signal types,
the FBs, the generated `*In`/`*Out` structs, the generated Loom glue, and `main.v`
all share that module. So FBs reference signals and `*In`/`*Out` directly — no
imports, no prefixes, no import cycle. Only the shared framework (`osal`, `loom`,
`driver.can`) is imported. See `examples/README.md`.

## Signal traceability — "follow a signal"

The signal **name** is the single thread you pull. It is used identically in FB
code, in `ecu.toml`, and is mapped to its DBC signal:

```
in.vehicle_speed   (FB code)
  └─ "VehicleSpeed" (ecu.toml signal + [[ioc]] channel)
       └─ DBC Powertrain.VehicleSpeed  (frame 0x100, bits 16|12, x0.1 km/h)
```

You follow it two ways, both **generated** (so always accurate):

1. **Inline** — go-to-definition on `in.vehicle_speed` lands on the generated
   field, whose doc comment states the DBC signal, frame, bit layout, scaling and
   path (see the `sig` struct above). One hop from FB code to DBC definition.
2. **A signal map** — `make trace` generates `docs/signal-map.md`:

   | Signal | Unit | Source | DBC signal | Frame | Layout | Scaling | Path | Consumers |
   |--------|------|--------|------------|-------|--------|---------|------|-----------|
   | VehicleSpeed | km/h | CAN can0 | Powertrain.VehicleSpeed | 0x100 | 16\|12 | x0.1 | COM→IOC(double)→app | SpeedMonitor |
   | WarnLamp | bool | app | LampFrame | 0x101 | 0\|1 | — | app→IOC→COM | (CAN tx) |

## Scaling & transformers — at the boundary, never in the FB

**Decision: FBs work in physical engineering units; raw↔physical scaling lives at
the communication boundary (COM), and any other transform is a declared,
generated step on the connection — not hand-written in the FB.**

- **Bus scaling (raw ↔ physical)** is the DBC `factor`/`offset`, applied in the
  generated COM codec (`dbc2cfg` emits `*_phys()`), so a signal read from CAN
  arrives already in km/h, °C, … The FB never sees raw bits.
- **Other transforms** (unit conversion, range clamp, end-to-end protection, rate
  limit) are **declared on the signal/connection** in config and emitted into the
  generated path. They run where the signal crosses a boundary, so every consumer
  sees the transformed value and the FB stays a pure function.

Rationale: keep FBs free of representation concerns — portable across ECUs and bus
matrices, testable with plain physical values, unaffected when a DBC scaling or a
transform changes.

```toml
[[ioc]]
name = "VehicleSpeed"   # physical km/h after COM scaling
from = "io"
to   = "app"
# transform = "clamp:0..350"   # optional, generated; FB still just reads km/h
```

## Signal validity

A signal carries validity: an IOC channel never written reads back as "no value
yet" (zero value with `valid = false` by convention). FBs must handle "not yet
received" — as `SpeedMonitor` does with `in.vehicle_speed.valid`.

## Worked example — FB → FB chaining

A filter FB sits between the bus and the monitor. `SpeedMonitor` is **unchanged** —
it doesn't know its input now comes from another FB instead of the bus.

```v
// app/speed_filter.v
pub struct SpeedFilter {
pub mut:
	last u16
}
pub fn (mut fb SpeedFilter) on_10ms(inp sig.SpeedFilterIn, mut out sig.SpeedFilterOut) {
	fb.last = (fb.last * 3 + inp.vehicle_speed_raw.kph) / 4 // simple IIR
	out.vehicle_speed = sig.VehicleSpeed{ kph: fb.last, valid: inp.vehicle_speed_raw.valid }
}
```

```toml
# ecu.toml: chain bus -> SpeedFilter -> SpeedMonitor
[[ioc]]
name = "VehicleSpeedRaw"; from = "io";  to = "app"; transport = "double"
[[ioc]]
name = "VehicleSpeed";    from = "app"; to = "app"; transport = "double"  # FB->FB
[[ioc]]
name = "WarnLamp";        from = "app"; to = "io";  transport = "double"

[[fb]]
name = "SpeedFilter"; partition = "app"
  [[fb.handler]]
  name = "on_10ms"; period_ms = 10; reads = ["VehicleSpeedRaw"]; writes = ["VehicleSpeed"]

[[fb]]
name = "SpeedMonitor"; partition = "app"
  [[fb.handler]]
  name = "on_10ms"; period_ms = 10; reads = ["VehicleSpeed"]; writes = ["WarnLamp"]
```

Re-sourcing `VehicleSpeed` from the bus instead of `SpeedFilter` is a one-line
config edit; neither FB changes.

## Communication topology — all transparent to the FB

The FB always just reads/writes a named signal. **Where** it lives is config,
resolved in the generated glue:

| Signal connects… | Generated glue uses | FB code |
|---|---|---|
| FB → FB, same partition | a local cell (direct memory, no sync) | identical |
| FB → FB, different cores | IOC channel (transport per `[[ioc]]`) | identical |
| FB ↔ communication bus | COM codec + driver (CAN/LIN/…) | identical |

Because the FB code is identical in all three cases, you can move an FB to another
core, or re-source a signal from the bus instead of another FB, **without touching
the FB** — only `ecu.toml` changes.

## Decisions (resolved)

- **Name**: **Function Block (FB)** — config `[[fb]]`. Avoids the ISO 26262
  unit/component overload and the AUTOSAR application-component connotation;
  composes natively.
- **Signal API**: grouped, annotated `In`/`Out` port structs (stable signatures,
  field access, built-in traceability).
- **Scaling/transforms**: at the COM/connection boundary, generated — never inside
  an FB.
- **Traceability**: signal name is the key; inline provenance on generated fields +
  a generated `signal-map`.

## Implemented

- **Done**: FBs with grouped `In`/`Out` port structs; config `[[fb]]`; signal types
  + generated `*In`/`*Out` in the `sig` module; the snapshot glue via `loom2v`;
  scaling at the COM boundary (`dbc2cfg`); provenance comments on generated port
  fields + the `make trace` signal map (`docs/signal-map.md`).
- **Still to come**: FB→FB *same-partition* local routing (today every cross-FB
  signal uses an IOC channel); declared connection transforms (clamp/unit/E2E);
  multiple signal-bearing handlers per FB (today one).
