# Multi-core + comm-thread trace — design draft

> **Status: P3a DONE + vcan-verified; P3b/P3c next.** This is the design writeup for the
> multi-core trace-codegen phase (the "Next: multi-core" pointer in [trace-codegen.md](trace-codegen.md)),
> extending the inline single-core path from #54/#55/#56. The four decisions in
> [§6](#6-confirmed-decisions) are settled. **P3a is implemented and proven** by the
> `examples/trace_multicore` demo (two partitions, cores 0+1): a single dump command streams one
> self-describing ISO-TP block per core, and blobly_net decodes both natively with correct
> per-core handler mapping. P3b (comm thread visible) and P3c (ThreadX target) are next.

## 1. Where we are

The current trace path (`trace_inline` in [tools/loom2v/gen.v](../tools/loom2v/gen.v)) is deliberately
narrow. It fires only when **all** of these hold, and panics otherwise:

- exactly one fb-bearing partition (`single_part != ''`),
- pinned to **core 0**,
- **no COM bus bridge** (`!has_bridge` — no external signals, ISO-TP, or routes),
- host target (not bare-metal).

Under those constraints one `run(ch)` superloop owns everything: the trace-bus channel, the
profiled dispatch + capture hook, the TraceCmd/TraceRsp handshake, the ISO-TP dump of the frozen
ring, the HandlerStat heartbeat, and CpuLoad. It emits **FB records only** — a polled single-core
loop has no thread switches or ISRs, so `thread`/`thread+isr` levels are rejected
([gen.v:1126](../tools/loom2v/gen.v)).

The record wire format (from #54) is already multi-core-ready and blobly_net already decodes it
(PR blobly_net#21): entity kinds `ISR | THREAD | FB | CONTROL`, a `CONTROL/ctl_block` **per-core
block header** (core + record count), and `CONTROL/ctl_epoch` timeline re-anchors. The dump is one
ISO-TP payload of N per-core blocks; the host reassembles `mask_popcount(mask)` blocks. **So the
protocol does not change in this phase — only the generator and the runtime wiring do.**

The panics that mark the boundary (all in `gen.v` around 458–475, 1126, 1133):

| Panic | Closed by |
|-------|-----------|
| `[trace] on an app with a COM bus bridge … not generated yet` | [§4 (P3b)](#p3b--comm-thread-visible) |
| `trace codegen currently supports a single partition on core 0 only` | [§3 (P3a)](#p3a--host-multi-core-fb-only) |
| `level "…" needs thread/ISR events … single-core host capture does not have` | [§4 (P3b)](#p3b--comm-thread-visible) / [§5 (P3c)](#p3c--threadx-target) |
| `cross-bus telemetry with inline trace is not generated yet` | [§3 (P3a)](#p3a--host-multi-core-fb-only) |
| `[trace] on a bare-metal [target] is not generated yet` | [§5 (P3c)](#p3c--threadx-target) |

## 2. What "the comm thread visible in the trace" means

Today the bus bridge is a **polled per-bus loop** (`partition_<bus>()`, [gen.v:919](../tools/loom2v/gen.v))
that drains `recv`, decodes rx→IOC, encodes IOC→tx, and serves ISO-TP/UDS + routing. It is **not**
in the manifest's `# threads` section — only app threads are ([gen.v:1364](../tools/loom2v/gen.v)) —
so it is invisible in the swimlane. Per [architecture.md](architecture.md) the target model makes it
a **first-class comm thread per bus** so *every* thread — app and platform — appears by name and the
bridge/ISO-TP overhead (often where the time goes) is never hidden.

Concretely, "visible" = the bridge gets **(a)** a manifest `thread` row (name = `comm_<bus>`), and
**(b)** it pushes `THREAD`-kind trace records for its own run intervals, so the swimlane shows a
`comm_can0` lane interleaved with the app lanes.

## 3. Host multi-core — **P3a**

The first mergeable slice: N partitions on M cores, no bridge. This is the "single partition on core
0 only" panic, lifted. Two properties make the multi-core view coherent and honest:

**System-wide freeze (coherent snapshot).** Each core's ring is a flight recorder, but a trigger
must freeze *every* core around the same instant — otherwise core A freezes at its anomaly while core
B keeps recording until `Stop`, and their dump windows don't overlap (the first thing that looks
wrong). So an overrun on any core sets a shared `osal.scratch` freeze flag, and every core's capture
hook then `trigger()`s its own ring (idempotent via its pending/state guards). `partition_trace`
clears the flag on re-arm. Result: all cores' windows cover the same moment.

**Derived thread + idle (honest `thread+fb`).** A polled host superloop is one *cooperative* thread —
no preemptive switches or ISRs — so we synthesise the schedule it actually runs: an fb record per
handler, a `THREAD` record bracketing each busy iteration (the thread ran these handlers, `reason =
yield`), and an `IDLE` record (thread id 0) for the gap since the last busy span (emitted lazily, so
idle records are bounded by the handler rate, not the 1 ms tick). So `thread+fb` shows a thread lane
per core plus idle — not just handler bars. Real *preemptive* thread/ISR interleaving is the ThreadX
target (P3c); the comm/platform thread becoming visible is P3b.

**Per-core rings in a shared trace region.** Each partition already runs its own spawned superloop
(`partition_<name>`, [gen.v:643](../tools/loom2v/gen.v)) pinned to its core. Give each its **own**
`TraceBuffer` + backing array — no cross-core sharing on the write path, so capture stays lock-free
(consistent with [[ioc-perf]]: cross-core state is never allowed to spin). The backing arrays live in
a **shared trace region** (same mechanism as the IOC region / `osal.scratch`) so the dump owner can
read them.

**One dump owner.** The loop that owns the **trace-bus channel** runs the TraceCmd/dump handshake
(as today). On `op_dump` with a core mask, it freezes each selected core's ring and packs them into
one ISO-TP payload — a `ctl_block` header + that core's records, per selected core, in mask order.
`trace.pack_block` already preserves per-block prefix epochs; this phase adds the multi-block
aggregation loop. The freeze is a flag the owner sets in each ring's shared header; the producing
core observes it at its next `buf.push` and stops writing (wait-free, one writer / one reader flag).

**HandlerStat fan-out.** Today the owner reads `sched.handler_stat(i)` for its own partition. For
other cores, each core publishes its handlers' `(last_us, max_us, count)` into the shared region
(the same way `osal.scratch_set` already publishes `load_permille`, [gen.v:656](../tools/loom2v/gen.v));
the owner reads them and emits one HandlerStat frame per global handler id. Global ids are already
assigned across all partitions in the manifest ([gen.v:1359](../tools/loom2v/gen.v)).

**Cross-bus telemetry** (the [gen.v:1133](../tools/loom2v/gen.v) panic) falls out naturally once the
owner is no longer the *only* loop: CpuLoad can go out on `[telemetry].bus` from that bus's owner
while trace rides `trace.bus`.

Deliverable: a `trace_multicore` example (2 partitions, cores 0+1, fb-only) that dumps two blocks;
`cmd/trace_dump` already prints multi-block, and the swimlane already lanes-by-core.

## 4. Comm thread visible — **P3b**

Lift the **bridge coexistence** panic and add THREAD records.

- The bridge loop (`partition_<bus>`) gets a **thread id + manifest row** (`comm_<bus>`, its core)
  and a capture hook that pushes a `THREAD` record per drain cycle: `new_thread(tid, reason,
  start_us, dt)` where `dt` is the time that cycle spent in COM/codec/ISO-TP. This is the first
  `THREAD`-kind producer on the host — it's an **interval** (a loop's work slice), not a real RTOS
  switch, which is exactly how blobly_net#21 now renders threads (duration bars, not switch marks).
- `thread+fb` level now has real thread records to emit; `thread` (no fb) becomes valid too.
- Trace + bridge on the **same** bus: one loop owns the channel and does both COM and the trace
  handshake. On **different** buses: the trace-bus owner runs the handshake; the bridge loop only
  produces records. Both cases share the per-core ring model from P3a.

Open question below on THREAD granularity (per-cycle vs per-rx-batch).

## 5. ThreadX target — **P3c**

Real threads + ISRs, bare-metal. This is the largest slice and genuinely different from host:

- Capture is driven by the **TX execution-change-notify hooks** (verified firing under QEMU M7 —
  [[threadx-execution-hooks-verified]]), not by a polled loop instrumenting itself. A real context
  switch emits a `THREAD` record for the outgoing thread's slice; the CAN **Rx interrupt** emits
  `ISR` records. `irq`-triggered handlers (reserved today, [model.v](../tools/ecumodel/model.v)) get
  generated here.
- The comm thread becomes a real ThreadX thread (rx driven by the Rx ISR, tx periodic) rather than a
  polled loop.
- `thread+isr` / `all` levels light up fully. Bare-metal + trace panic lifts.

This depends on the ThreadX port work and is the natural place to stop for now — P3a/P3b deliver the
"comm thread visible" goal on the sim-first host, which is where everything is proven before target.

## 6. Confirmed decisions

1. **Scope of the first PR: P3a alone** — host multi-core, fb-only, per-core rings + aggregated
   multi-block dump. It's the load-bearing infra and is verifiable on vcan without any thread-record
   semantics. P3b (comm thread) stacks on top. *The live HandlerStat heartbeat fan-out across cores
   is split into a P3a follow-up so the first PR stays focused on the dump path — the CpuLoad
   fan-out (via `osal.scratch`, the existing `partition_telem` pattern) rides along in P3a.*

2. **Shared trace region: reuse on host, revisit for target.** The per-core rings are owned by
   `run()` (fixed arrays on its frame, which outlives the joined partitions) and passed by pointer —
   no globals, no heap. The dump owner reads every ring through that registry. CpuLoad fan-out keeps
   using `osal.scratch`. A dedicated MPU-isolated trace region is a target concern (P3c).

3. **THREAD-record granularity (P3b): per bridge drain cycle** first; refine on the target where the
   real switch hooks give true boundaries.

4. **Dump ownership: single owner.** One `partition_trace()` loop owns the trace-bus channel, runs
   the TraceCmd/Rsp handshake, and on `op_dump` freezes + `pack_block`s each selected core's ring
   into one ISO-TP message per core (mask order). This matches the one-stream / N-blocks model the
   blobly_net dump worker already expects (it `recv`s `mask_popcount(mask)` blocks).

## 7. P3a runtime shape (generated)

```
run(<trace_bus> can.Channel):
    mut backings := [ncores][cap]trace.Record{}    # run() owns the rings so the owner can read them
    mut rings    := [ncores]trace.TraceBuffer{}
    for each app partition p:
        rings[p.core] = trace.new_buffer(&backings[p.core][0], cap, mode, pre)
        rings[p.core].start()
        spawn partition_<p>(&rings[p.core])          # p pushes FB records into its own ring
    spawn partition_trace(&rings[0], ncores, ch)     # single owner: handshake + dump
    <join>

partition_<p>(mut ring &trace.TraceBuffer):
    pin_to_core(p.core); set_trace_hook(capture, {ring, start, base}); loop { run_profiled; account; scratch_set(load); sleep }

partition_trace(mut rings &trace.TraceBuffer, ncores int, ch can.Channel):
    pin_to_core(trace_bus.core)
    loop:
        recv → on TraceCmd: handle_cmd; on op_dump: for c in selected(mask): rings[c].stop(); pack_block(dumpbuf, c); isotp.send  # one message per core
        CpuLoad from scratch (partition_telem pattern)
```

Cross-thread freeze note (host): the owner calls `rings[c].stop()` on a buffer the producer writes;
`push` checks state first, so it self-quiesces. A single torn record at the exact freeze instant is
acceptable for a diagnostic ring on the sim host (the wire format + net decoder tolerate one garbage
record). The ThreadX target (P3c) freezes with real synchronization.
