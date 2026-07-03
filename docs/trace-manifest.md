# Handler trace manifest (the `_net` decode/label interface)

The trace frames carry a 1-byte **global `handler_id`** and raw microsecond counts — no
strings. The **manifest** is the small, config-derived table that turns those into named,
grouped, deadline-aware timeline lanes. It is the interface a visualization tool
(blobly_net) loads alongside the frame decoders; `loom2v` will generate it from
`ecu.toml`. See [telemetry.md](telemetry.md) for the wire formats it complements.

`examples/trace_demo/trace-manifest.json` is a working fixture (the 3-handler demo).

## Schema (v1, JSON)

```jsonc
{
  "version": 1,               // manifest schema version
  "time_unit_us": 1,          // unit of every *_us field on the wire and here (µs today)
  "frames": {                 // only the ids this ECU actually emits (config, not fixed)
    "loaddetail_id":  2017,   // 0x7E1  LoadDetail  (present iff LoadDetail is sent; the
                              //        trace_demo fixture omits it — it sends no load)
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
  ]
}
```

## How a tool uses it

| Field | Drives |
|---|---|
| `handlers[].id → fb/handler` | lane label + colour; the key for every HandlerStat/Record `b0` |
| `handlers[].core` | grouping into per-core swimlanes |
| `handlers[].period_us` | deadline marker; jitter = actual period (Δ`start_us`) − this |
| `time_unit_us` | unit for all `*_us` fields (last/max/start/cpu) |
| `frames.*` | which CAN ids to subscribe/decode (so ids aren't hard-coded) |
| `frames.record_id` + `frames.dump_fc_id` | the ISO-TP address pair for the Record dump: reassemble on `record_id`, send flow-control on `dump_fc_id` |

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
