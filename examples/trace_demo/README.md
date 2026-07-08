# trace_demo — handler runtime tracing, generated from `ecu.toml`

A single-core handler-tracing demo (host / vcan) that is **fully generated** from
[`ecu.toml`](ecu.toml) by `loom2v` — the config-driven counterpart of the
[runtime-tracing design](../../docs/telemetry.md). The only hand-written source is
[`main.v`](main.v) (open the channel → `gen.run(ch)`) and the three pure-compute FBs in
[`app/work.v`](app/work.v); everything else — the loom wiring, the trace capture ring +
`TraceCmd`/`TraceRsp` + ISO-TP dump, the `HandlerStat` heartbeat, and `CpuLoad` — is emitted
into `gen/loom_gen.v`, plus `gen/trace-manifest.csv` (handler/thread names + the trace frame
ids) for blobly_net, which decodes the fixed observability protocol natively.

Three handlers run on one Loom at different periods (all mapped to the `app_main` thread):

| fb id | fb | handler | period | work |
|---|---|---|---|---|
| 0 | FastWork | on_5ms | 5 ms | light |
| 1 | MedWork | on_10ms | 10 ms | medium |
| 2 | SlowWork | on_20ms | 20 ms | heavy (glitches every 40th run) |

`run_profiled` brackets **each** dispatched handler and records its response time; every
`push_ms` the loop emits one **HandlerStat** on `0x7E4` (per docs/telemetry.md), and it feeds
one trace `Record` per invocation into a `buffer_records`-deep **ring** (flight recorder). The
`[trace].trigger` (`source = "overrun", budget_us = 500`) freezes the ring around any handler
that runs longer than the budget — SlowWork's periodic glitch — keeping `pre_pct` % of the
window from before it.

## Run it

```sh
make vcan          # bring up vcan0 (once)
make run &         # generate + build + run on vcan0
make watch         # candump vcan0,7E4:7FF — the HandlerStat frames
```

## Control + dump

The capture is host-driven over a cmd/rsp protocol (not UDS): an 8-byte `TraceCmd` on `0x7E2`,
reply `TraceRsp` on `0x7E3` (opcode, result, state, records_used, capacity). `dump` streams the
frozen ring as one **ISO-TP** block on `0x7E5` (flow control from the host on `0x7E6`). Start
the ISO-TP receiver first, then dump:

```sh
candump vcan0,7E3:7FF &                # the TraceRsp replies
isotprecv -s 0x7E6 -d 0x7E5 vcan0 &    # reassemble the dump (needs the can-isotp kernel module)
cansend vcan0 7E2#0700000000000000     # status -> state 3 (frozen) once the glitch has fired
cansend vcan0 7E2#0600000000000000     # dump   -> rsp, then the 512-byte block (64 × 8-byte records)
cansend vcan0 7E2#0400000000000000     # reset  -> state 1 (capturing again)
```

`dump` is refused (`result_not_ready`) unless the ring is frozen/full — you never stream a
buffer that's still being written. Or just open the generated `gen/trace-manifest.csv` in
blobly_net and drive it by name.

## Notes

- **Config-driven.** Change a period, the buffer depth, the trigger budget, or a frame id in
  `ecu.toml`, `make`, and the wiring + DBC + manifest regenerate together — nothing is
  hand-kept, so the trace can't drift from the app it traces.
- **Response vs CPU time.** On this polled host loop with no interrupts the bracketed duration
  is the handler's CPU time; under ISRs/preemption it is response time (see the design doc).
- **Single-core.** loom2v folds the trace into one `run(ch)` superloop that owns the channel;
  multi-core trace (IOC fan-out + a comm thread) is the next phase.
