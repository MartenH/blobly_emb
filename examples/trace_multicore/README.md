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
fans out over **IOC**: it forwards the command to each selected core, which applies it to
**its own** buffer and replies a `TraceRsp`; on `dump` the owning core streams its frozen
buffer to the bus core in 64-byte IOC chunks (stop-and-wait), and the bus core reassembles
it and sends it as **one ISO-TP block** on `0x7E5`. Each block is **self-describing**: a
leading block-header record names the core and record count, so a tool splits the stream by
core with no timing correlation. Blocks stream one at a time (serialised on `0x7E5`),
ascending core order; a second `dump` while one is in flight is rejected `result_busy`.

A dump that selects a **single** core (a one-bit `core_mask`, or the zero-mask core-0 path)
streams **raw records** with no block header — the `TraceRsp` already names the core, so
the header would only mislead single-core tooling. The per-core header appears only when
`core_mask` selects more than one core.

**No remote buffer access.** Each core touches only its own `TraceBuffer` (single-writer);
the bus core reaches a core solely through `osal.ioc_*` — never a direct cross-core read.
The cores are cooperative loops in one host process here (osal keeps the IOC region in a
static block — the host-Linux stand-in for the target's shared SRAM), but the control and
read-out paths are the real AMP ones. On silicon the same `osal.ioc_*` calls cross cores.

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

## Watch it in blobly_net

`trace-multicore.blobnet` (+ `trace-manifest.csv`) is a ready-made blobly_net project: open
it, Start the channel, and press **Dump** in the Trace Chart — blobly_net freezes both cores,
dumps them in one command, reassembles the per-core ISO-TP blocks, and draws the multi-core
swimlane (handler bars + thread-switch marks). A copy also ships at
`blobly_net/projects/trace-multicore.blobnet` (blobly_net resolves the manifest from its own
working dir). Run this demo first (`make vcan && make run`).

## Run it (raw CAN)

```sh
make vcan                                 # bring up vcan0
make run &                                # build + run on vcan0
make watch &                              # candump vcan0,7E3:7FF — TraceRsp, one per core (b7)
isotprecv -s 0x7E6 -d 0x7E5 vcan0 &       # reassemble a block (-d rx = data 0x7E5, -s tx = FC 0x7E6)

# status both cores in one command (core_mask = 0x0003): two TraceRsp replies
cansend vcan0 7E2#0700000000000300

# freeze both rings, then dump both cores in one command -> two ISO-TP blocks on 0x7E5
cansend vcan0 7E2#0300000000000300        # opcode 3 = stop  -> rsp state 3 (frozen) x2
cansend vcan0 7E2#0600000000000300        # opcode 6 = dump  -> two self-describing blocks
```

`dump` needs each ring **frozen** first — send `stop` (or let the heavy handler's periodic
glitch fire the trigger), else a core replies `result_not_ready` and sends no block. On this
kernel without `can-isotp` you can still see it work: two `TraceRsp` per command
(`06 00 03 .. 00` core 0, `.. 01` core 1) and two ISO-TP first-frames on `0x7E5` whose
headers read `00 40 20 00` (core 0, 32 records) and `01 40 20 00` (core 1) — the whole block
crossed IOC to the bus core.

`isotprecv` needs the `can-isotp` kernel module for the full reassembly; the block framing
is also covered deterministically by `comm/trace/multicore_dump_test.v` (two cores, two
blocks, through an in-process ISO-TP Link pair).

## Notes

- **Hand-wired.** Mirrors what loom2v will generate (the `core_mask` fan-out + per-core
  dump from `ecu.toml`); a dev harness, not a config-driven example.
- **Record kinds.** A dumped stream is not homogeneous: check `flags` bit7 (thread-switch)
  and bit6 (block-header) per record; both clear = a handler run. See
  [docs/trace-manifest.md](../../docs/trace-manifest.md).
