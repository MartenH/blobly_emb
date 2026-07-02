# trace_demo — handler runtime tracing, P1 (host / vcan)

The first slice of the [runtime-tracing design](../../docs/telemetry.md) (Part 2, P1):
**per-handler execution timing** measured by the Loom and pushed over CAN as a
**HandlerStat** frame, watchable live with `candump`. Develops and verifies the
`loom.run_profiled` + `comm/telem.encode_handlerstat` path on WSL before it becomes
config-driven codegen.

Three handlers run on one `loom.Scheduler` with different periods and workloads:

| handler_id | period | work |
|---|---|---|
| 0 | 5 ms | light |
| 1 | 10 ms | medium |
| 2 | 20 ms | heavy |

`Scheduler.run_profiled(clock)` brackets **each** dispatched handler with the clock and
records its response time (last / max / count). Once a second the loop pushes one
**HandlerStat** frame per handler on `0x7E4`:

```
b0    handler_id
b1    flags
b2-3  last_us      (u16 LE)  response time of the last invocation
b4-5  max_us       (u16 LE)  peak since the previous report
b6-7  count_delta  (u16 LE)  invocations in the last second
```

## Run it

```sh
make vcan          # bring up vcan0
make run &         # build + run on vcan0
make watch         # candump vcan0,7E4:7FF
```

You should see three frames a second, e.g. (decoded):

```
handler | last_us | max_us | count/s
   0     |    3    |   15   |  178      # ~5 ms period, light work
   1     |   25    |  147   |   96      # ~10 ms, medium
   2     |   98    |  401   |   49      # ~20 ms, heavy
```

`count/s` tracks the periods; `last`/`max` scale with each handler's work — the Loom's
per-handler timing, live on the bus.

## Notes

- **Hand-wired.** This mirrors what the loom2v HandlerStat emitter will generate; it is
  a dev harness, not a config-driven example (no `ecu.toml`). It proves the mechanism on
  the host so the target and codegen build on something verified.
- **Response vs CPU time.** On this polled host loop with no interrupts, the bracketed
  duration is the handler's CPU time. Under ISRs/preemption it is response time; CPU time
  then needs the ISR/ThreadX accounting described in the design doc.
- **Next**: fold this into loom2v (emit the HandlerStat push + a handler manifest from
  `ecu.toml`), then the captured trace buffer + cmd/rsp control (P2).
