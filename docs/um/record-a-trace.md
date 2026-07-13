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

## Triggers and modes

`[trace.trigger]` freezes the ring around an event instead of on Stop — e.g.
`source = "overrun"` with `budget_us` catches the first handler that blows its budget,
keeping `pre` percent of history (proven on the host runner; see
[../trace-codegen.md](../trace-codegen.md) for what each target shape generates).

## Gotchas

- The ring free-runs from boot; Record just re-arms (clears) it — you can Dump without
  ever pressing Record and get the last `buffer_records` events.
- A dump takes tens of ms per core on classic CAN — the board stays live; re-dump if a
  host timeout left a stale stream (the module answers busy while streaming).
- Trace ids are in the manifest — regenerate + reload it after adding threads or FBs,
  or lanes show synthetic names (`thread 9`, `handler 7`).
