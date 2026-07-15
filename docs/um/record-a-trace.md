# How do I record and view a trace?

The trace is a flight recorder per core: thread switches + ISRs (ThreadX exec-change
hooks) and per-handler FB runs (the Loom hook), timestamped in µs, dumped over the bus
as self-describing blocks. Design: [../trace-multicore.md](../trace-multicore.md),
[../com-modules.md](../com-modules.md).

## 1. Enable it in ecu.toml

```toml
[trace]
enabled        = true
bus            = "can0"
level          = "all"        # thread+isr, or "all" to include FB handler bars
buffer_records = 256          # ring depth (multi-block dump: not payload-limited)
mode           = "ring"       # free-running flight recorder
cmd            = 0x7E2        # command / response / record stream / dump flow-control
rsp            = 0x7E3
record         = 0x7E5
dump_fc        = 0x7E6
```

- **Bindings take a DBC name too**: `cmd = "TraceCmd"` resolves the id from `bus.dbc`
  and validates the DLC — same rule as every module endpoint binding.
- **RAM**: a record is 8 bytes, but the target holds several copies of the window —
  the C recorder ring (`boards/common/trace_hooks.c`, `RING_CAP` 256 = 2 KB), the
  freeze/snapshot scratch (2 KB), the module's decoded ring (2 KB), plus one imported
  ring per satellite core on the dump owner. 256 records ≈ 6 KB single-core, ≈ 8 KB on
  a two-core owner. Config cap is 4096 (32 KB per copy). Keep `buffer_records` equal
  to the platform `RING_CAP` — smaller truncates the window, larger buys nothing.
- **Modes**: `ring` (overwrite-oldest flight recorder, the default) and `oneshot`
  (fill once, freeze). The ThreadX target implements ring ONLY and fails generation
  otherwise; oneshot is a host-runner mode.

`make gen` wires the recorder, the command routing, and writes
`gen/trace-manifest.csv` — the identity table (handler/thread names per core) every
viewer loads. Satellites get their own recorder automatically; the owner remains the
single dump owner.

## 2. Capture

**GUI** (blobly_net): load the manifest, open the Trace panel — Record / Stop / Dump.
The core mask is derived from the manifest, so on a two-core node one Stop freezes both
windows.

**CLI**:

```sh
cd ../blobly_net
v -enable-globals -path "@vlib|@vmodules|modules" run cmd/trace_dump \
    can0 0x3 ../blobly_emb/examples/h755_threadx/gen/trace-manifest.csv
```

`0x3` = core mask (bit per core). The tool arms, stops, and streams every selected
core's window; blocks decode with named threads and handlers.

## 3. Read the swimlane

- One lane per (core, thread), plus ISR lanes; FB handler runs draw as bars nested in
  their thread's slice (`level = "all"`).
- `reason` on a thread record says why it left the core (preempted / blocked / tick).
- Overruns: a handler bar longer than its thread's tick budget — cross-check with the
  `stat` shell command (max µs per handler).

## Triggers

`[trace.trigger]` freezes the ring around an event instead of on Stop:

```toml
[trace.trigger]
source    = "overrun"    # freeze when a handler exceeds its budget
budget_us = 500
pre       = 50           # keep this % of history before the trigger point
```

Host runner only today (proven on vcan in `examples/trace_demo`). The ThreadX target
**fails generation** if a trigger is configured — deliberately, so it can't silently
build a continuous ring you believed was triggered. See
[../trace-codegen.md](../trace-codegen.md) for what each target shape generates.

## Gotchas

- The ring free-runs from boot; Record just re-arms (clears) it — you can Dump without
  ever pressing Record and get the last `buffer_records` events.
- A dump takes tens of ms per core on classic CAN — the board stays live; re-dump if a
  host timeout left a stale stream (the module answers busy while streaming).
- Trace ids are in the manifest — regenerate + reload it after adding threads or FBs,
  or lanes show synthetic names (`thread 9`, `handler 7`).
