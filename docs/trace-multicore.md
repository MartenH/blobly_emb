# Multi-core + comm-thread trace — design draft

> **Status: P3a DONE + merged (single-writer, #57); P3b DONE + merged (different-bus, #60); P3c-0
> DONE (bare-metal single-core trace); P3c-1 (real thread/ISR capture) next.**
>
> **REGRESSED IN GENERATION (#191).** Both host examples below still build and run their FBs, but
> loom2v now emits the trace ring + dump for the SINGLE-partition host shape only and warns when
> it drops the rest, so neither answers a `dump` today. The platform side never changed —
> `comm/trace` still carries one local core plus one imported remote, and `multicore_dump_test`
> proves the two-block read-out. What follows describes the design, not what generation currently
> produces.
> The design writeup for the multi-core trace-codegen phase, extending the inline single-core path
> from #54/#55/#56. **P3a is shipped** — `examples/trace_multicore` (two partitions, cores 0+1): a
> single dump command streams each core's window as self-describing blocks (multi-block with a
> continuation more-flag since emb#116), coherent single-writer
> cross-core freeze, decoded natively by blobly_net. **P3b (comm thread visible) is shipped** — the
> per-bus COM bridge is a traced `comm_<bus>` thread (`examples/trace_comm`), different-bus reusing
> the P3a owner; same-bus (piggyback) is the remaining follow-up. **P3c-0 (bare-metal single-core
> trace) is shipped** — `examples/h735_app` now enables `[trace]` and the target reuses the inline
> machinery on the board's DWT clock (§5). P3c-1 (real preemptive thread/ISR capture via the TX
> execution-change hooks) is the larger remaining slice. The P3 phases carry **no backward-compat
> burden** (§4.4).

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
block header** (core + record count + a more-flag in bit 7 of the core byte for multi-block
continuation), and `CONTROL/ctl_epoch` timeline re-anchors.

> **`ctl_epoch` is not cross-core sync.** It re-anchors the u24 `start_us` base *within* one
> core's stream for long captures; it says nothing about how two cores' clocks relate. Each core
> counts µs from its own first tick — the CM7 boots first and releases the CM4 later, so at the
> same instant the two clocks read different values — and a swimlane drawn from the raw blocks
> silently implies a shared timeline it does not have. `CONTROL/ctl_coreoffset` is what actually
> correlates them (REQ-TRACE-011); see below. A core's window streams as one or
more self-describing blocks (each re-anchored by a leading epoch); the host reads blocks until
every selected core's final (more = 0) block arrives — end-of-stream lives in the format, so the
same stream rides ISO-TP today and any future transport unchanged. **So the
protocol does not change in this phase — only the generator and the runtime wiring do.**

The panics that mark the boundary (all in `gen.v` around 458–475, 1126, 1133):

| Panic | Closed by |
|-------|-----------|
| `[trace] on an app with a COM bus bridge … not generated yet` | [§4 (P3b)](#p3b--comm-thread-visible) |
| `trace codegen currently supports a single partition on core 0 only` | [§3 (P3a)](#p3a--host-multi-core-fb-only) |
| `level "…" needs thread/ISR events … single-core host capture does not have` | [§4 (P3b)](#p3b--comm-thread-visible) / [§5 (P3c)](#p3c--threadx-target) |
| `cross-bus telemetry with inline trace is not generated yet` | [§3 (P3a)](#p3a--host-multi-core-fb-only) |
| `[trace] on a bare-metal [target] supports exactly one partition` (single-core is BUILT; multi-partition target) | [§5.1 (P3c-1)](#51-real-threads--isrs--p3c-1) |

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
(as today). On `op_dump` with a core mask, it freezes each selected core's ring and streams each
core's window as one or more self-describing blocks — `ctl_block` header (with the continuation
more-flag) + a leading epoch + that core's records — per selected core, in mask order, one
transport transfer per block. `trace.pack_chunk` packs from a continuation cursor and preserves
epoch anchoring per block. The freeze is a flag the owner sets in each ring's shared header; the producing
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

## 4. Comm thread visible — **P3b** (different-bus BUILT; same-bus next)

> **Shipped:** the different-bus slice (§4.3) — `examples/trace_comm` (an app FB on core 1 + a
> `VehicleSpeed` external signal → a `comm_can0` bridge on core 0 + a dedicated trace bus `can1`).
> The bridge loop is instrumented as a traced comm thread (ring + THREAD/idle spans per drain cycle
> + a `comm_can0` manifest row + the P3a single-writer coordination), and `partition_trace` on `can1`
> reads its ring — verified on vcan: the dump shows a `comm_can0` lane beside the app lanes. The
> **same-bus** piggyback case (§4.3) is the remaining follow-up.

Lift the `has_bridge` trace panic ([gen.v:473](../tools/loom2v/gen.v)) and make each per-bus bridge a
**first-class traced comm thread**, so COM/codec/ISO-TP/routing overhead shows as its own lane — the
"platform never hidden" goal from [architecture.md](architecture.md).

### 4.1 The bridge as a traced entity (both bus cases share this)

The bridge loop today is `partition_<bb>()` ([gen.v:1141](../tools/loom2v/gen.v)) — a `loom.Scheduler`
running `io_<bb>_10ms` (the COM drain) every 10 ms, structurally the same shape as a traced app
partition. So instrument it with the **exact P3a machinery**:

- Give it a per-core ring in the `run()`-owned registry (its core = `bus_core[bb]`), a `TraceCapture`
  (with its own `trig_slot`, `thread_id`, `id_base`), and the `trace_capture` hook.
- Bracket the drain like a traced app partition: a **THREAD record per busy iteration**
  (`new_thread(comm_tid, reason_yield, start, dt)`, `dt` = time in COM/codec/ISO-TP this cycle) +
  an IDLE record for the gap. Granularity = **per drain cycle** (decision §6.3); refine on the target.
- It gets a `thread_id` and a manifest row `thread,<tid>,comm_<bb>,<core>`, numbered **after** the app
  threads (extend the `# threads` emission at [gen.v](../tools/loom2v/gen.v) to also walk the bridges).
- No FBs, so it emits only THREAD/idle — which is why `thread` (no fb) becomes a valid level here.

The bridge participates in the P3a single-writer coordination unchanged: its capture hook bumps its
own trigger counter on an overrun (a comm cycle over budget), and it applies routed arm/stop/reset/
freeze commands to its OWN ring in its loop.

### 4.2 Core + ring model

The per-core registry (`rings[ncores]`) now indexes **app partitions AND comm threads** by core.
Keep the P3a invariant: **one traced entity per core, dense 0..N-1**. Typical layout — the comm
thread(s) on the IO core(s), the app partition(s) on their cores. `trace_ncores`, `fb_id_base`,
`thread_id_of`, and the dense-core / core≥16 / scratch-cell guards all extend to count comm threads.
`run()` creates + starts a ring per comm thread and spawns each `partition_<bb>` with its ring
pointer, exactly like a traced app partition.

### 4.3 Channel ownership — the one real fork

- **Different-bus (do first — reuses P3a cleanly).** Trace rides a bus with **no** bridge, so
  `partition_trace` owns that channel and runs the handshake + dump exactly as in P3a; the bridge on
  its own bus is just another producer whose ring `partition_trace` reads. **Zero new handshake
  code** — only §4.1/§4.2. First example: `trace_comm` — one app partition + one external signal
  (→ a bridge on the IO core) + a dedicated trace bus; the dump shows a `comm_<bus>` lane beside the
  app lanes.
- **Same-bus (follow-up — the realistic piggyback case).** Trace shares the app bus, so the **bridge
  loop must be the trace owner**: its single `recv` on that channel dispatches by id —
  `id == cmd_id` → the TraceCmd handshake (route commands, status_rsp, freeze fan-in); `id == dump_fc`
  → feed `isotp.Link`; else → the existing COM path. It also drives the per-core dump (`pack_block` +
  ISO-TP), interleaved with COM. This merges `partition_trace`'s body into `partition_<bb>` for the
  trace bus, and drops the separate `partition_trace`/`run()`-owner spawn when the trace bus has a
  bridge. Invasive (touches the generated COM recv), so it's its own PR after different-bus proves the
  comm-thread instrumentation.

### 4.4 No backward-compat burden (P3 stance)

blobly_emb (the target) and blobly_net (the host) move together — there are no third-party consumers
of the trace wire, manifest, or codegen. So **break freely**: the wire format (record kinds, TraceRsp
layout, the b2 state/cause nibble), the manifest columns, and the generated shape can all change in
lockstep across the two repos without preserving old behavior. Don't spend code on compatibility
shims or zero-mask legacy paths — update both ends and the docs. (This is why codex's compat-flavored
findings — e.g. the TraceRsp nibble vs. an "older decoder" — are non-issues: there is no older
decoder we don't also own.)

### 4.5 Not in P3b

Real preemptive thread/ISR interleaving, the Rx-interrupt-driven comm thread, and `irq` handlers stay
in **P3c** (the ThreadX target). P3b keeps the cooperative-loop model — the comm thread is a *work
slice per drain cycle*, an interval, not a real context switch.

## 5. ThreadX target — **P3c**

### 5.0 Bare-metal single-core trace — **P3c-0 (BUILT)**

The smallest, provable-now slice: `[trace]` on a single-core `[target]` reuses the **inline** trace
machinery verbatim — the same `trace_capture` hook, `TraceCmd`/`TraceRsp` handshake, ISO-TP dump of
the frozen ring, HandlerStat heartbeat, and CpuLoad as the host `trace_demo`. The only substitutions
the emitter makes for the target (`trace_target := trace_on && target_on`, [gen.v](../tools/loom2v/gen.v)):

- **clock**: `C.board_now_us()` (the board's DWT µs counter) instead of `osal.now_us()`, via a small
  `board_clock()` V wrapper passed to `run_profiled`/`account`. No osal is imported or referenced.
- **idle**: a busy-wait to a fixed `tick_us` boundary (real idle for load accounting — [[loom-load-baremetal-pacing]]), instead of `osal.sleep_us`.
- **no `pin_to_core`** (single core).

Shipped in `examples/h735_app` (add `[trace]` to its `ecu.toml`, regenerate, cross-compile): the
generated `gen/loom_gen.v` builds V→C→`arm-none-eabi-gcc`→`app.bin` and links against the FDCAN
backend (`blob_can_recv`) + board bring-up. It's the host-proven flight recorder, now on silicon,
over the one FDCAN bus. It captures **fb + derived thread/idle** records only — there are still no
real preemptive switches or ISRs on a polled superloop, so `level` stays `thread+fb`/`all`.

### 5.1 Real threads + ISRs — **P3c-1**

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
   no globals, no heap. A dedicated MPU-isolated trace region is a target concern (P3c).

   *Update (as shipped in #57): the coordination is fully **single-writer** on the host — the owner
   never mutates a remote ring. arm/stop/reset are ROUTED to the owning partition via a per-core
   `osal.scratch` command cell (which that partition applies to its own ring), the reply is a
   read-only `status_rsp`, and an overrun freeze is fanned in via a per-core trigger counter (edge-
   detected, snapshotted on arm) then out as a freeze command. The one remaining direct access is the
   owner **reading** each frozen ring for the `pack_block` dump — safe on the host (shared memory,
   producer quiesced), and the IOC-chunked read-out that replaces it is deferred to **P3c** (on the
   target's MPU a direct remote read is impossible).*

3. **THREAD-record granularity (P3b): per bridge drain cycle** first; refine on the target where the
   real switch hooks give true boundaries.

4. **Dump ownership: single owner.** One `partition_trace()` loop owns the trace-bus channel, runs
   the TraceCmd/Rsp handshake, and on `op_dump` freezes + `pack_block`s each selected core's ring
   into one ISO-TP message per core (mask order). This matches the one-stream / N-blocks model the
   blobly_net dump worker already expects (it reads blocks until every selected core's
   final more = 0 block — multi-block since emb#116/net#45).

## 6b. Cross-core time correlation (REQ-TRACE-011)

Per-core rings solve *who ran what*; they do not make two cores' timestamps comparable. Every core
stamps records from `trace_now_us()` in `boards/common/trace_hooks.c`, which counts µs from **that
core's first call** (a DWT-CYCCNT accumulator scaled by a per-core `TRACE_CPU_MHZ` — 400 on the
CM7, 200 on the CM4). The CM7 boots first, brings up the clock tree and only then releases the
CM4, so the two origins are offset by the boot handoff. Drawing both blocks on one axis without
correcting for that is the failure this closes: the chart looks right and is wrong.

The rates do **not** drift apart — both cores run off the same HSE/PLL tree, and `TRACE_CPU_MHZ`
already normalises each to µs — so a single scalar offset is sufficient; there is no skew term to
track.

**The measurement rides the handoff that already exists.** The dtrace cell in `xcore.h` is a
request/ack exchange the bus owner performs on every snapshot, which is exactly the round trip a
clock sync needs:

| stamp | who | when |
|---|---|---|
| `t1` | CM7 | immediately before `req_seq++` releases the request |
| `t2` | CM4 | in `xcore_trace_service()`, just before it acks (cell word `XCORE_TRC_SVC_IDX`) |
| `t3` | CM7 | on the polling pass that **first** observes the ack |

`t2` lies somewhere in `[t1, t3]`, so `offset = t2 − (t1+t3)/2` and the error is bounded by
`(t3−t1)/2`. Both are emitted as a `CONTROL/ctl_coreoffset` record that `load_remote()` prepends
to the satellite's block. Because the exchange runs per dump, the offset is re-measured every
time — a CM4 that reset, or a debugger that halted one core, cannot leave a stale offset behind.

Two deliberate choices:

- **Never fabricate a zero.** If no exchange has completed, `xcore_trace_offset()` returns 0 and the
  record is omitted entirely. A 0 offset would assert perfect correlation — the exact false
  precision this record exists to remove — so "unknown" stays visibly unknown.
- **Both stamps come from the recorder's own clock**, not SysTick or an RTOS tick. Correlating a
  clock the records aren't stamped from would measure a skew they don't have.

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
