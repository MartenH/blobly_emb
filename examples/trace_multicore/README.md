# trace_multicore — multi-core dump + thread-switch swimlane, P4 (host / vcan)

The P4 slice of the [runtime-tracing design](../../docs/telemetry.md#part-2--handler-runtime-tracing-design):
**one command dumps several cores**, and the dump carries the **thread-switch (swimlane)
timeline**, not just handler bars. It develops and verifies the `core_mask` control +
per-core self-describing ISO-TP blocks + the thread-switch record kind on WSL before they
become config-driven codegen.

Two simulated cores run on one bus loop, each a `loom.Scheduler` with its own ring
`TraceBuffer`:

| core | handler_id | fb    | period | thread ids |
|---|---|---|---|---|
| 0 | 0 (light), 1 (heavy) | light/heavy | 5 ms / 20 ms | app0=0, isr0=1 |
| 1 | 2 (light), 3 (heavy) | light/heavy | 5 ms / 20 ms | app1=2, isr1=3 |

## Multi-core dump in one command

A single `TraceCmd` addresses several cores through **`core_mask`** (b6-7, bit *i* = core
*i*; a zero mask = the receiving core, so single-core commands are unchanged). The bus core
fans out: for each selected core it applies the command, sends that core's `TraceRsp`, and
— on `dump` — streams that core's buffer as **its own ISO-TP block** on `0x7E5`. Each block
is **self-describing**: a leading block-header record names the core and record count, so a
tool splits the stream by core with no timing correlation. Blocks stream one at a time
(serialised on `0x7E5`), ascending core order.

On a real AMP target the bus core pulls each core's frozen buffer over **IOC** (never a
direct cross-core read); here the two buffers are in one process, but the control + framing
path is identical.

## Thread-switch swimlane

Switches are captured as a **record kind** in the *same* ring as handler runs (flag bit7),
so one dump is a single timeline of *who ran* and *the context switches between them*. A
switch record carries `from_thread`, `to_thread`, and a reason (preempt / block / resume /
ISR). Decoded via the manifest's `threads[]` table, blobly_net draws one lane per thread
and shades the interval a thread is switched out.

> **Synthetic on host.** Real switches come from the ThreadX `TX_THREAD_STATE_CHANGE` hook;
> the cooperative host has no preemption, so this harness *injects* synthetic `app<->isr`
> switches to exercise the codec and dump end-to-end — the same seam-only stand-in as the
> DWT `hw` trigger. On silicon the hook replaces the injection; nothing else changes.

## Run it

```sh
make vcan                                 # bring up vcan0
make run &                                # build + run on vcan0
make watch &                              # candump vcan0,7E3:7FF — TraceRsp, one per core (b7)
isotprecv -s 0x7E6 -d 0x7E5 vcan0 &       # reassemble a block (-d rx = data 0x7E5, -s tx = FC 0x7E6)

# status both cores in one command (core_mask = 0x0003): two TraceRsp replies
cansend vcan0 7E2#0700000000000300

# dump both cores in one command: two self-describing ISO-TP blocks on 0x7E5
cansend vcan0 7E2#0600000000000300
```

`isotprecv` needs the `can-isotp` kernel module. Without it, the command fan-out and the
per-core TraceRsp are still observable on `candump` (as `07 .. 00` for core 0 and
`07 .. 01` for core 1), and the ISO-TP block reassembly is covered deterministically by
`comm/trace/multicore_dump_test.v` (two cores, two blocks, through an in-process ISO-TP
Link pair).

## Notes

- **Hand-wired.** Mirrors what loom2v will generate (the `core_mask` fan-out + per-core
  dump from `ecu.toml`); a dev harness, not a config-driven example.
- **Record kinds.** A dumped stream is not homogeneous: check `flags` bit7 (thread-switch)
  and bit6 (block-header) per record; both clear = a handler run. See
  [docs/trace-manifest.md](../../docs/trace-manifest.md).
