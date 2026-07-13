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
name      = "on_100ms"         # == the method name on the struct
period_ms = 100                # the only trigger today (irq is reserved)
reads     = ["Command"]        # optional; signal names -> In ports
writes    = ["LoadCmd"]        # optional; signal names -> Out ports
```

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
