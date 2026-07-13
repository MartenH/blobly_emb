# How do I add a function block?

An FB (component) is a V struct in the example's `app/` module plus a `[[fb]]` block
binding it to a thread. One method per handler; the generator writes the state struct,
the dispatch wrapper, the schedule registration, and the trace/stat identity.

## 1. Declare it

```toml
[[fb]]
name   = "Governor"            # unique identifier == the app struct's type name
thread = "ctrl_slow"           # a [[partition.thread]] name (globally unique)

[[fb.handler]]
name      = "on_100ms"         # == the method name on the struct (see below)
period_ms = 100                # the only trigger today (irq is reserved)
reads     = ["Command"]        # optional; signal names -> In ports
writes    = ["LoadCmd"]        # optional; signal names -> Out ports
```

The handler name is NOT magic — `on_100ms` is convention, not syntax. Any valid
identifier works: `name = "foobar"` means the FB's struct (the `app/` type named by
`[[fb]] name`, here `Governor`) needs a `foobar` method — the generated wrapper calls
`st.governor.foobar(inp, mut outp)`. That name match (plus the struct-type match on
`[[fb]] name`) is the ENTIRE config→code binding; no registration step, and a mismatch
is a compile error naming the missing method. The handler name is also the wrapper
symbol (unique within the FB) and the label in the manifest/trace/`stat`. The schedule
comes ONLY from `period_ms` — nothing checks the name against it, so an `on_100ms`
running at `period_ms = 10` would mislabel itself to every human reader. Keep the
convention honest.

Rules ecucheck/loom2v enforce: every FB needs ≥ 1 handler; every handler needs
`period_ms`; the thread must exist. Comments above blocks, never inside.

## 2. Write the app code

`app/fbs.v` (or any file in `app/`):

```v
module app

import ports

pub struct Governor {
pub mut:
	level u32          // private state: plain struct fields, defaults allowed
}

pub fn (mut g Governor) on_100ms(inp ports.GovernorIn, mut outp ports.GovernorOut) {
	// pure V, no-alloc, bounded work: read inp.<signal>, write outp.<signal>
	outp.load_cmd.iters = next_level(inp.command.code)
}
```

The signature never grows: a handler always takes exactly `(inp, mut outp)` — every
signal in `reads`/`writes` is a FIELD of those generated structs, so 20 inputs and 10
outputs is still two parameters (`inp.wheel_speed_fl`, `outp.brake_cmd`, ...). The
wrapper fills ALL of `inp` before the call, so the handler computes on a coherent
snapshot — inputs never change mid-run. Related values that are produced together
belong in ONE multi-field signal (`fields = { fl = "u32", fr = "u32", ... }`) rather
than four; and an FB wanting 20 unrelated inputs is often two FBs.

The handler must stay inside its period at the thread's tick — the scheduler marks
overruns and the trace makes them visible (`[trace] level = "all"` draws each handler
run as a bar inside its thread's lane).

## 3. Generate and build

```sh
make gen     # ports/GovernorIn/Out + wrapper + sched.every(...) appear in gen/
make
```

## What you get for free

- A **manifest row** (`gen/trace-manifest.csv`) with a stable global handler id — the
  trace GUI and `stat` shell command name the handler with zero extra wiring.
- **Per-handler stats** (`stat`: last/max/mean µs + count) and the per-thread load that
  telemetry ships as CpuLoad.
- On a satellite partition, the same declaration generates into the satellite's image
  instead — see [add-a-core.md](add-a-core.md).

## Placement notes

- FBs on the **same thread** run sequentially in declaration order; a local signal
  between them is a plain struct cell (fast path).
- A local signal read from **another thread** is rejected — cross-thread flow must be a
  declared signal so it gets an IOC cell ([add-a-signal.md](add-a-signal.md)).
- Threads have rate-monotonic priorities you control — put fast handlers on high-prio
  threads ([add-a-thread.md](add-a-thread.md)).
