# trace_demo — handler tracing served by the platform's TraceModule

A single-core handler-tracing demo (host / vcan), **fully generated** from
[`ecu.toml`](ecu.toml) — and the first consumer of the COM-module design
([docs/com-modules.md](../../docs/com-modules.md)): the trace protocol is the
**platform's `TraceModule`** (`comm/trace`), not generated code. The generated
`run(ch)` only *wires* it — the `[trace]` **endpoint bindings** route `cmd` to
`on_cmd` (the router match), `produce()` streams the response + dump back out,
and the platform `fb_hook` records each dispatched handler into the ring. The
only hand-written source is [`main.v`](main.v) (open the channel → `gen.run(ch)`)
and the three pure-compute FBs in [`app/work.v`](app/work.v).

```toml
[trace]
level   = "fb"
cmd     = 0x7E2    # rx binding -> the generated router match calls tm.on_cmd
rsp     = 0x7E3    # tx binding -> the module stamps responses with this id
record  = 0x7E5    # tx binding -> the dump stream
trigger = { source = "overrun", budget_us = 500 }
```

Three handlers run on one Loom at different periods (all mapped to the `app_main` thread):

| fb id | fb | handler | period | work |
|---|---|---|---|---|
| 0 | FastWork | on_5ms | 5 ms | light |
| 1 | MedWork | on_10ms | 10 ms | medium |
| 2 | SlowWork | on_20ms | 20 ms | heavy (glitches every 40th run) |

`run_profiled` brackets **each** dispatched handler; `fb_hook` feeds one trace
`Record` per invocation into a `buffer_records`-deep **ring** (flight recorder).
The `[trace].trigger` (`source = "overrun", budget_us = 500`) freezes the ring
around any handler that runs longer than the budget — SlowWork's periodic glitch
— keeping `pre_pct` % of the window from before it.

## Run it

```sh
make vcan          # bring up vcan0 (once)
make run &         # generate + build + run on vcan0
candump vcan0      # CpuLoad 0x7E0 + the session below
```

## Control + dump

Host-driven over the module's cmd/rsp: an 8-byte `TraceCmd` on the `cmd` binding,
reply on `rsp` (opcode echo, result, state+cause, records_used, capacity). `dump`
streams the frozen ring as **raw 8-byte records** on `record`, oldest first:

```sh
candump vcan0,7E3:7FF &                # the TraceRsp replies
cansend vcan0 7E2#0700000000000000     # status -> state 3 (frozen) once the glitch has fired
cansend vcan0 7E2#0600000000000000     # dump   -> rsp, then 64 records on 0x7E5
cansend vcan0 7E2#0400000000000000     # reset  -> state 1 (capturing again)
```

Each record is `entity_id(LE) info start_us(u24,LE) cpu_us(LE)`; fb ids and frame
ids are in `gen/trace-manifest.csv` (the 5/10/20 ms periods show up as a ~4:2:1
record mix). `dump` is refused (`result_not_ready`) unless the ring is frozen/full
— you never stream a buffer that's still being written.

## Notes

- **Config-driven.** Change a period, the buffer depth, the trigger budget, or a
  binding in `ecu.toml`, `make`, and the wiring + manifest regenerate together —
  nothing hand-kept, so the trace can't drift from the app it traces.
- **Platform-owned protocol.** `arm/stop/dump/status` semantics live (and are
  unit-tested) in `comm/trace` — the generator emits a router match and a
  `produce` drain, nothing protocol-shaped. The HandlerStat heartbeat and the
  ISO-TP block dump return as `stat`/`dump_fc` endpoints when that code moves
  into the module; this config grows a binding each, nothing else changes.
- **Response vs CPU time.** On this polled host loop with no interrupts the
  bracketed duration is the handler's CPU time; under ISRs/preemption it is
  response time (see the design doc).
- **Single-core.** One `run(ch)` superloop owns the channel and the schedule;
  multi-core capture is the module's next slice.
