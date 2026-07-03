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

## Captured trace (P2)

Besides the live stats, the demo also **captures every invocation**: a loom trace hook
(`set_trace_hook`) feeds one `trace.Record` per dispatched handler into a 64-record
one-shot `TraceBuffer`. It auto-arms at start, fills, and **stops at full** — the records
are then retrieved on demand with a `dump` command (see *Control it* below); they are not
sent automatically. Each record is `b0 handler_id, b2-5 start_us, b6-7 cpu_us`.

Decoded, a dump is the per-invocation timeline — who ran when and for how long:

```
handler  start_us  cpu_us
  h2       1098      190     # slow (20 ms), heavy
  h1       3545       68     # med  (10 ms)
  h0       5813        4     # fast (5 ms), light
  h0      11435        6
  h1      13715       44
  ...
```

## Control it (P2, step 3)

The capture is **host-driven** over a cmd/rsp protocol (not UDS). Send an 8-byte
`TraceCmd` on `0x7E2`; the target replies with a `TraceRsp` on `0x7E3` (opcode, result,
state, records_used, capacity), and on `dump` streams the records on `0x7E5`.

```sh
candump vcan0,7E3:7FF,7E5:7FF &      # watch responses + the dump
cansend vcan0 7E2#0700000000000000   # opcode 7 = status  -> rsp: state 2 (full), used 64
cansend vcan0 7E2#0600000000000000   # opcode 6 = dump    -> rsp + 64 record frames
cansend vcan0 7E2#0400000000000000   # opcode 4 = reset   -> rsp: state 1 (capturing)
```

`dump` is refused (`result_not_ready`) unless the buffer is full/frozen — you never
stream a buffer that's still being written. The dump is one **ISO-TP** block on `0x7E5`
(flow control from the host on `0x7E6`) — the 64 records pack to 512 bytes. Reassemble it
with `isotprecv -s 0x7E6 -d 0x7E5 vcan0` (needs the `can-isotp` kernel module).

## Notes

- **Hand-wired.** This mirrors what the loom2v HandlerStat emitter will generate; it is
  a dev harness, not a config-driven example (no `ecu.toml`). It proves the mechanism on
  the host so the target and codegen build on something verified.
- **Response vs CPU time.** On this polled host loop with no interrupts, the bracketed
  duration is the handler's CPU time. Under ISRs/preemption it is response time; CPU time
  then needs the ISR/ThreadX accounting described in the design doc.
- **Next**: fold this into loom2v (emit the HandlerStat push + a handler manifest from
  `ecu.toml`), then the captured trace buffer + cmd/rsp control (P2).
