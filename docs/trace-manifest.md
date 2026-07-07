# Handler trace manifest (the `_net` decode/label interface)

The trace frames carry a 1-byte **global `handler_id`** and raw microsecond counts — no
strings. The **manifest** is the small, config-derived table that turns those into named,
grouped, deadline-aware timeline lanes. It is the interface a visualization tool
(blobly_net) loads alongside the frame decoders; `loom2v` will generate it from
`ecu.toml`. See [telemetry.md](telemetry.md) for the wire formats it complements.

`examples/trace_multicore/trace-manifest.json` is a working fixture (2 cores, 4 handlers).
(`trace_demo` is now generated from `ecu.toml` — see its `gen/trace-manifest.csv`, the CSV form
`loom2v` emits, which additionally carries the trace frame ids under `# trace frames`.)

## Schema (v1, JSON)

```jsonc
{
  "version": 1,               // manifest schema version
  "time_unit_us": 1,          // unit of every *_us field on the wire and here (µs today)
  "frames": {                 // only the ids this ECU actually emits (config, not fixed)
    "loaddetail_id":  2017,   // 0x7E1  LoadDetail  (present iff LoadDetail is sent)
    "cmd_id":         2018,   // 0x7E2  TraceCmd    (host -> target)
    "rsp_id":         2019,   // 0x7E3  TraceRsp
    "handlerstat_id": 2020,   // 0x7E4  HandlerStat (live per-handler stats)
    "record_id":      2021,   // 0x7E5  captured-trace Record dump (ISO-TP data: target -> host)
    "dump_fc_id":     2022    // 0x7E6  ISO-TP flow control the host sends for the Record dump
  },
  "handlers": [               // one entry per schedulable unit (an [[fb.handler]])
    { "id": 0,                // global handler_id — the b0 in every HandlerStat/Record
      "partition": "app",
      "core": 0,              // lane grouping / per-core swimlanes
      "fb": "fast",           // fb + handler = the lane label, e.g. "fast.on_5ms"
      "handler": "on_5ms",
      "period_us": 5000 }     // the deadline line + the jitter reference
  ],
  "threads": [                // one per partition (= ThreadX thread) — labels the swimlane
    { "id": 0,                // thread id: the from_thread/to_thread in a switch record
      "name": "app",          // lane label for the context-switch timeline
      "core": 0 }             // which core's swimlane the thread lives on
  ]
}
```

**Record kinds.** A dumped Record stream is not homogeneous — two `flags` bits mark the
kind (see `telemetry.md`): `bit7` = a **thread-switch** event (`b0` = to_thread, `b6` =
from_thread, `b7` = reason; `b2-5` = start_us), `bit6` = a **block-header** (`b0` = core,
`b2-5` = record count that follows) — present **only in a multi-core dump**, one per core,
to split the shared stream (a single-core dump has no header and is just records). Both
bits clear = a normal handler-run record. A decoder checks the kind per record: run
records → the handler timeline via `handlers[]`, switch records → the context-switch
timeline via `threads[]`, header records → start a new core's block.

## How a tool uses it

| Field | Drives |
|---|---|
| `handlers[].id → fb/handler` | lane label + colour; the key for every HandlerStat/Record `b0` |
| `handlers[].core` | grouping into per-core swimlanes |
| `handlers[].period_us` | deadline marker; jitter = actual period (Δ`start_us`) − this |
| `time_unit_us` | unit for all `*_us` fields (last/max/start/cpu) |
| `frames.*` | which CAN ids to subscribe/decode (so ids aren't hard-coded) |
| `frames.record_id` + `frames.dump_fc_id` | the ISO-TP address pair for the Record dump: reassemble on `record_id`, send flow-control on `dump_fc_id` |
| `threads[].id → name/core` | lane label + core for the context-switch (swimlane) timeline; the key for a switch record's from/to thread |

A **multi-core dump** (one `dump` with several `core_mask` bits) arrives as one ISO-TP
block per core, each led by a block-header record naming its core and count — so the tool
splits by core without correlating to the TraceRsp timing.

Recipe: load the manifest → decode LoadDetail / HandlerStat / Record (layouts in
`telemetry.md`; the `encode_*` fns in `comm/telem` and `comm/trace` are ground truth) →
render the **swimlane timeline** (a `cpu_us`-wide bar at `start_us` per `handler_id`),
**per-handler gauges** (HandlerStat last/max/count), and **jitter/overrun** overlays.

## Status

- **Stable to build against now:** the frame layouts + these field semantics.
- **Pending:** `loom2v` generation of this file from `ecu.toml` (today it's the hand-
  written fixture above), and the ISO-TP bulk-dump framing for the Record stream.
- Ids and `time_unit_us` are explicit in the manifest precisely so a tool never bakes
  them in.
