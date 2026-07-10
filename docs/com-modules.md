# COM modules — trace, NM, telemetry as routed clients

How platform capabilities (trace, network management, telemetry) attach to the
bus **without any of them being special**. The load-bearing idea: a frame id can
route to a **module**, not just a signal. Once that's true, trace is a row in the
routing table — the same as NM, the same as everything.

> This is the design that came out of stripping trace from the generator. Trace
> had grown to ~1000 lines smeared through 50% of `tools/loom2v/gen.v` because
> loom2v was **generating a control protocol** (TraceCmd/Rsp poll loop, ISO-TP
> dump, multi-core coordination) once per run-model. That protocol is really just
> **routing + a producer** — COM's job, done by hand. See
> [communication.md](communication.md), [nm.md](nm.md).

## The one generalisation: routes terminate at a signal *or* a module

Today `ecu.toml` routes `frame → signal → IOC cell`. We add `frame → module` as a
first-class route. The **routing table is the single source of truth**: every id
in the config points at a signal or a module, by id (`0x712`) or by DBC name.

```toml
# frame -> signal (today): decoded into an IOC cell
[[route]]  id = 0x123  to = "Command"        # a signal

# frame -> module (new): delivered to the module's on_rx
[[route]]  id = 0x712  to = "trace"          # the trace control frame
[[route]]  id = 0x400  to = "nm"             # an NM frame
```

Nothing about `to = "trace"` is trace-specific. The generator sees a route whose
destination is a module and wires it the same way for any module.

## The COM-module interface (platform, written once)

Trace, NM and telemetry all implement the same tiny interface. The platform owns
it; loom2v never generates its body.

```v
interface ComModule {
    rx_ids() []u32                 // ids this module claims (drives the routing table)
    on_rx(f can.Frame)             // a routed frame arrived (trace: handle_cmd; NM: state machine)
    produce(mut out []can.Frame)   // hand COM whatever it wants to send this pass (tx_ready-gated)
}
```

- **`on_rx`** is the control plane. Trace: `trace.handle_cmd(mut ring, decode_cmd(f))`
  (already in `comm/trace`). NM: its message handler. It's just "a frame came in."
- **`produce`** is the data plane. Telemetry: CpuLoad every period. Trace: records
  from the hooks, or a **dump burst** once a dump command armed it (an on-demand
  producer — same category as telemetry's periodic one, different trigger). NM:
  its periodic messages.

## The generic comm loop (platform, capability-agnostic)

The comm thread — the thing loom2v used to hand-generate ~700 lines of, per
run-model — is now one loop that names no capability:

```
for {
    drain rx:  for each frame  ->  module = route[frame.id];  module.on_rx(frame)
    produce:   for each module ->  module.produce(mut out);   send out (tx_ready-gated)
    pace / sleep
}
```

Written once in the platform/comm. Host, ThreadX and bare-metal differ only in how
the loop is *hosted* (spawned thread vs comm thread vs inline superloop) and how it
reads the clock/channel — not in what it does.

## Trace = data from hooks + control by routing

Trace stops being a subsystem loom2v generates and becomes a `ComModule` plus three
**enter/exit hook families** that feed its ring — the recording model, unchanged and
already mostly present:

| event      | enter/exit source                              | record        |
|------------|------------------------------------------------|---------------|
| **ISR**    | Cortex-M / port exec-change hooks              | `new_isr`     |
| **thread** | RTOS (ThreadX exec hooks) / Loom on host       | `new_thread`  |
| **FB**     | Loom scheduler brackets each handler dispatch (`sched.set_trace_hook`, exists) | `new_fb` |

The hooks timestamp and push a `Record` into the ring. The trace module streams the
ring out via `produce` when a routed command arms it. `comm/trace` already has the
primitives: `handle_cmd`, `TraceBuffer`, `new_isr/new_thread/new_idle/new_fb`,
`status_rsp`. The **only** missing platform piece is the module wrapper + the generic
loop — neither of which is trace-specific.

## What loom2v generates (thin) vs what's platform (once)

**Platform library** (`comm/`, written + unit-tested once, no codegen):
- the generic comm loop (route + produce),
- `ComModule` and the concrete modules: `TraceModule`, `NmModule`, `TelemModule`,
- the trace owner logic (dump streaming, multi-core coordination) *inside* `TraceModule`.

**loom2v generates** (the same generation for every module):
- the **routing table** from `ecu.toml` (id → signal | module),
- entity-id / ring-size / scratch-cell **assignment**,
- **registration**: instantiate each configured module, hand it its config, add it
  to the comm thread's module list,
- **hook wiring**: FB enter/exit via the Loom scheduler (thread/ISR are port/RTOS).

That's it. `gen_trace.v` collapses from ~1000 lines of generated protocol to a
handful of lines of config — "trace is a module routed at `0x712`, 64-entry ring,
records on `0x7E5`." NM lands the same way with no new generator code.

## Why this is the fix, not another move

Every earlier attempt (extract emitters, a `Producer` interface, relocate to
`gen_trace.v`) moved the **generated owner-loop** around. The loop shouldn't be
generated at all — it's COM routing + a producer, and COM already owns routing.
Delete the generation; let the platform own the loop; make trace a routed client.
The strip (`gen.v` 3231 → 2192, trace fully removed, non-trace byte-identical) is
the enabling baseline; this doc is the re-add.
