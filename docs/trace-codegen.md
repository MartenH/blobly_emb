# Trace subsystem from `ecu.toml` (loom2v codegen) — design

**Status: in progress.** Landed so far (P1 tooling): loom2v reads `[trace]` and writes the five
observability frame ids into the **manifest** (arg 6); `ecumodel` validates the block (bus
resolves, `level`/`mode` enums, `pre_pct`/`buffer_records` ranges). **No `trace.dbc` is
generated** — the observability protocol (`TraceCmd`/`TraceRsp`/`HandlerStat` + the ISO-TP record
dump) is fixed and first-party, so blobly_net decodes it natively from the ids in the manifest;
re-encoding a fixed protocol as a per-ECU DBC (and then policing its ids against every other
frame on the bus) was churn without payoff. Each id is either a literal CAN id (yours to
allocate — no collision policing) or the **name of a message in `bus.dbc`** (resolved to its id,
required to exist). The example conversion (generated `main.v` + loom, retiring the hand-wired
harness) lands next, on top of the `entity_id`/interval `comm/trace` record rework — see §5.

Today the runtime-tracing subsystem is *hand-wired* in
`examples/trace_multicore` (and `trace_demo`), and its manifest + DBC are hand-written. This
doc proposes generating **all of it from `ecu.toml`** via loom2v, so nothing is hand-kept and
nothing can drift — the same way the Loom wiring and COM codec already are.

Complements [telemetry.md](telemetry.md) (the wire protocol, unchanged) and
[trace-manifest.md](trace-manifest.md) (the `_net` interface).

## What already exists (reused, not regenerated)

The generation only *wires* these — the runtime code stays in the libraries:

- `loom` — `run_profiled(clock)`, per-handler `HandlerStat`, the `RunHook` trace seam.
- `comm/trace` — `TraceBuffer` (ring/oneshot), record kinds, `handle_cmd`, `pack`/`pack_block`.
- `comm/telem` — `encode_handlerstat` / `encode_cpuload` / `encode_loaddetail`.
- `comm/isotp` — the ISO-TP `Link` for the bulk dump.

And `ecu.toml` **already** carries everything the manifest needs:
`[[partition]]` (name, core) and `[[fb]]` → `[[fb.handler]]` (name, `period_ms`).

## 1. `ecu.toml` — the `[trace]` block

A single new block (sibling of `[telemetry]`, which stays as-is for load). Everything has a
default so a bare `enabled = true` works:

```toml
[trace]
enabled        = true
bus            = "can0"     # the CAN channel the cmd/rsp + dump ride (defaults to [telemetry].bus)
buffer_records = 64         # per-core ring depth (static array; RAM vs depth)
mode           = "ring"     # "ring" (flight recorder) | "oneshot"
pre_pct        = 50         # ring pre/post-trigger split
push_ms        = 1000       # live HandlerStat heartbeat period (0 = off)
# frame ids: a literal CAN id (yours to allocate) OR a bus.dbc message name (defaults shown)
cmd_id         = 0x7E2
rsp_id         = 0x7E3
stat_id        = 0x7E4      # HandlerStat heartbeat
record_id      = 0x7E5      # ISO-TP dump data (target -> host)
dump_fc_id     = 0x7E6      # ISO-TP flow control (host -> target)
```

No handler/core/thread lists here — those are **derived** from the partitions + FBs already
declared, so the trace config can't disagree with the app it traces.

**Frame ids — number or name.** Each id above is either a **literal CAN id** (used as-is;
allocating a non-colliding id is the author's job — loom2v does *not* police it against other
traffic) or the **name of a message in `bus.dbc`**, e.g. `cmd_id = "TraceCmd"`, which loom2v
resolves to that message's id (and errors if it isn't in the DBC). So you either hand it an id,
or point it at a frame you've already defined — nothing in between to validate.

## 2. Generated artifacts

From one `ecu.toml`, loom2v emits the wiring + the manifest (there is **no** generated DBC —
see §c):

### a) `gen/trace_gen.v` — the target wiring
Generated into the per-core loop loom2v already builds (`gen/loom_gen.v`), or a sibling file:
- switches each core's `sched.run()` → **`run_profiled(clock)`** and installs the capture
  hook feeding a per-core `TraceBuffer` sized `buffer_records` (`mode`/`pre_pct`).
- the **HandlerStat heartbeat** (`push_ms`) — each core builds its own frames, published to
  the bus core over **IOC** (the cross-core-isolation invariant; single-core skips IOC).
- the **cmd/rsp + ISO-TP dump** on `cmd_id`/`rsp_id`/`record_id`/`dump_fc_id`, including the
  **multi-core `core_mask` fan-out** — generated from the partition→core topology (the
  per-core blocks + IOC read-out that `trace_multicore` does by hand).

### b) `gen/trace-manifest.csv` — the `_net` label interface
One row per handler + one per thread, from the partitions/FBs (matches what loom2v emits):
```
# id,partition,core,fb,handler,period_us,thread
0,sense,0,SpeedFilter,on_10ms,10000,main
...
# thread,id,name,core   (id 0 reserved = idle)
thread,1,sense.main,0
thread,2,ctrl.main,1
```
- **`handler_id`**: assigned **globally, stably** across all partitions in declaration order
  (partition, then fb, then handler) — the existing manifest contract. The trailing `thread`
  column names the thread the handler runs on.
- **threads**: one row per `[[partition.thread]]`, `id` assigned globally from **1** (id 0 is
  reserved for idle, the THREAD-kind sentinel), `name` = `partition.thread`, 0-based `core`.
  (ISRs get no row — an ISR's id *is* its raw vector.)

The manifest also carries the five observability frame ids (resolved from `[trace]`) so
blobly_net knows where the traffic is:
```
# trace frames: frame,id,bus
cmd,0x7E2,can0
rsp,0x7E3,can0
stat,0x7E4,can0
record,0x7E5,can0
dump_fc,0x7E6,can0
```

### c) No generated `gen/trace.dbc`
The observability protocol (`TraceCmd`/`TraceRsp`/`HandlerStat` + the ISO-TP record dump) is
**fixed and first-party** — its layouts and value tables (`opcode 6 → "dump"`, `state → frozen`,
…) live once in `comm/trace` + `comm/telem` and never vary per ECU; only the five ids do. So we
do **not** generate a DBC that re-encodes that fixed format per ECU (and then has to have its
ids policed against every app/isotp/nm/route frame on the bus — churn with no payoff).
**blobly_net decodes the protocol natively** from the ids in the manifest. If you *want* a trace
frame to be a named DBC message (for generic DBC-tool interop), give the id as a `bus.dbc`
message name (§1) — then it's already in your DBC and there's nothing to generate.

_net change: blobly_net reads the five ids from the manifest's `# trace frames` rows and applies
its built-in decoders. (Named ids also appear in `bus.dbc`, which it already loads.)

## 3. Resolve the two manifest formats

Today there's a **JSON** schema (`trace-manifest.json` / `trace-manifest.md`) *and* a **CSV**
that `_net` actually parses — a divergence you flagged. **Proposal: CSV is the generated,
canonical format** (it's what `_net` loads; trivial for codegen; `#` comments allowed). The
JSON becomes documentation-only or is dropped. `telemetry.md`/`trace-manifest.md` get updated
to describe `ecu.toml → generated CSV manifest + DBC` as one story.

## 4. What a `blobly_net` project looks like (also generatable)

The `.blobnet` + its relative `manifest:`/`databases:` paths point at the generated
`gen/trace-manifest.csv` + `gen/trace.dbc`. loom2v can emit a ready-to-open `gen/<ecu>.blobnet`
too, so "watch this ECU in blobly_net" is one generated file. (Optional — say if you want it.)

## 5. Scope / phasing

1. **P1 — manifest + DBC generation.** loom2v reads `[trace]`, emits `trace-manifest.csv` +
   `trace.dbc`. Lowest risk, immediately removes the hand-written files. `make`-wired.
2. **P2 — heartbeat + per-handler timing.** Generate `run_profiled` + capture hook + the
   HandlerStat push into the per-core loop. Verify on vcan (sim-first).
3. **P3 — cmd/rsp + ISO-TP dump + multi-core fan-out.** Generate the full read-out path;
   the hand-wired `trace_multicore` becomes a generated example built from an `ecu.toml`.
4. **P4 — retire the hand-wired demo** in favour of the generated one; optional `.blobnet`
   generation.

Each phase is a PR, verified sim-first on vcan, driven through Codex review.

## 6. Open decisions (your call)

1. **Config home:** a new **`[trace]`** block (proposed) vs. nesting under `[telemetry]`.
2. **Manifest format:** **CSV canonical** (proposed) vs. keep JSON too.
3. **Generated `.blobnet`:** emit one per ECU (proposed optional) vs. leave projects hand-made.
4. **Multi-core in the first cut:** generate the IOC fan-out from the start (proposed) vs.
   single-core first, multi-core in P3.
5. **File layout:** fold trace wiring into `gen/loom_gen.v` vs. a separate `gen/trace_gen.v`
   (proposed, keeps the diff readable).
