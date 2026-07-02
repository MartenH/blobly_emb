# Runtime observability: processor load + handler runtime tracing

The stack observes its **own** runtime and ships it over CAN, so a running ECU can be
watched live in any CAN tool (candump, or the blobly_net GUI decoding it via DBC) — no
`/proc`, no external profiler, no debug probe.

Two layers, from cheap-and-always-on to detailed-and-on-demand:

1. **Processor load** — a small, continuous per-core load percentage (implemented).
2. **Handler runtime tracing** — per-handler (per-FB) execution timing, optionally
   preemption-aware, captured into a buffer and read out on command (design below).

A **handler** is one `[[fb.handler]]` — the schedulable unit loom registers with
`sched.every(...)`. We say *handler* (the stack de-AUTOSAR's names: runnable→handler),
never "task"; at the RTOS level the OS unit is a ThreadX **thread** (a partition runs as
one thread), which is where preemption lives.

---

# Part 1 — Processor load (implemented)

Each `Scheduler` brackets the time it spends in `run()` and rolls it into a duty cycle
over several windows at once — `load_permille_100ms/1s/10s()`, 0..1000. This is
*handler work / wall clock*: the useful-work fraction (it excludes poll/sleep overhead,
so it reads a little lower than a `top`-style figure). `REQ-TELEM-001` (single window),
`REQ-TELEM-003` (multiple concurrent windows).

The generated telemetry tx reports it on the bus:

- **`CpuLoad` (0x7E0)** — one byte per core = load percent over the 1 s window
  (`comm/telem.encode_cpuload`). `REQ-TELEM-002`.
- **`LoadDetail` (0x7E1)** — one core's load over the 100 ms / 1 s / 10 s windows plus
  its per-period **overrun** count (`encode_loaddetail`). The 100 ms window surfaces
  bursts the 1 s figure averages away; a non-zero overrun byte means commanded work
  exceeded the core's capacity. The observable overrun **count** is `REQ-TELEM-004`; the
  run loop *detects* an overrun (a pass over its tick) and increments it — that detection
  is verified on target (the h735 LoadDetail pulse) and moves into loom per-handler in
  P1. Reporting the detail frame is proposed `REQ-TELEM-005` (Part 2 — not yet tracked,
  target-only today).

```toml
[telemetry]
enabled   = true
bus       = "can0"
id        = 0x7E0    # CpuLoad
detail_id = 0x7E1    # LoadDetail (optional; omit to send only CpuLoad)
period_ms = 500
```

On the host the tx is a spawned thread that sums each scheduler's `load_permille()` by
core; on the bare-metal single-core target (`[target] baremetal`) it is sent inline from
the generated `run()` loop, reading `load_permille*()` directly. The load is only valid
when the loop yields **genuine idle** between passes (the fixed-tick pacing) — an unpaced
free-running loop would read a bogus ~50 % floor.

**Current limits.**
- **`LoadDetail` is target-only.** The `[target] baremetal` emitter sends `0x7E1`; the
  host `partition_telem()` sends `CpuLoad` only. On the host, `detail_id` is accepted but
  no `0x7E1` is produced (host generation is a follow-up).
- **16 schedulers.** The host telemetry sums load through a 16-slot shared scratch area
  (`slot_core.len < 16`); a config with more partitions + bus bridges than that reports
  the first 16 and silently omits the rest.

---

# Part 2 — Handler runtime tracing (design)

Processor load answers *"how busy is the core?"*. This layer answers *"where does the
time go?"* — the runtime of each individual handler, so you can find the one that blew
its budget, see scheduling jitter, and catch preemption. Nothing here is built yet; this
is the shape before the requirements and code.

## Identity: a generated manifest with globally-unique handler IDs

Because everything is generated from `ecu.toml`, the handler set is known at build time
on **both** ends. loom2v emits a **handler manifest** — a flat table with a **globally
unique** `handler_id` assigned across *all* partitions (not a per-scheduler index, which
would collide: in a 2-partition app every scheduler's first handler is 0). Example for a
multi-partition config (`overspeed`, partitions `sense` + `ctrl`):

```
handler_id | partition | core | fb            | handler   | period_us
0          | sense     | 1    | SpeedFilter   | on_10ms   | 10000
1          | sense     | 1    | WheelWatch    | on_10ms   | 10000
2          | ctrl      | 2    | SpeedMonitor  | on_10ms   | 10000
3          | ctrl      | 2    | LampDriver    | on_20ms   | 20000
```

The target tags every record/stat with the 1-byte global `handler_id`; blobly_net
resolves `handler_id → name / core / period` from the **same manifest** it loads next to
the DBC. So the target never sends strings and the map can't drift — one source of truth.

> **Decision — shared manifest over runtime announce.** A self-describing target (send a
> handler-table frame at startup) is more robust to a host/target manifest mismatch and
> supports hot-attach, but costs bus traffic, a string protocol, and a second identity
> path. Recommendation: **shared manifest**; add an *optional* announce frame later only
> if field mismatches bite.

## What we measure: two clocks

Every handler invocation has two useful durations, equal only when nothing interrupts:

- **Response time** (wall clock): `now` after the handler − `now` before — what a loom
  bracket measures. It includes any time an **ISR** ran, or (on an RTOS) any time the
  thread was **preempted**, during the handler.
- **CPU time** (execution): response time **minus** interrupt/preempt time — the true
  cost of the handler on the core.

On the **cooperative loom** an FB handler runs to completion and is never preempted by
*another FB*. But the bracket is **not** automatically exact CPU time: on bare-metal any
ISR that fires mid-handler lands inside the bracket, and on an RTOS a higher-priority
thread can preempt the partition thread. So the loom bracket is **response time**; it
equals CPU time only when nothing interrupts — which *is* true for a fully-polled core
with no enabled peripheral IRQs (the h735_app demo), but not in general. CPU time needs
interrupt/preemption accounting (below).

## Mechanism

### loom (all targets) — per-handler bracket → response time

`loom.Scheduler.run()` already times the whole pass. Extend it to bracket **each**
dispatched handler and fold the duration into a per-handler stat:

```
for each due handler i:
    t0 = now()
    handlers[i](ctx[i])
    dt = now() - t0
    stat[i].last = dt; stat[i].max = max(max, dt); stat[i].count++; stat[i].total += dt
```

Fixed-memory (one `HandlerStat` per scheduler slot, no alloc); gives last/max/mean
response time and invocation count per handler. Cost: two `now()` reads per dispatch —
negligible with the DWT cycle counter. On a no-IRQ polled core this is also exact CPU
time; where ISRs run, subtract the ISR time (an ISR-duration counter the OSAL exposes).

### ThreadX (preemptive) — profile kit + state-change hook → CPU time

When partitions run as ThreadX threads, the thread can be preempted (ISRs,
higher-priority threads). To get true CPU time and see preemption:

- Enable ThreadX's **execution-profile kit** (`TX_EXECUTION_PROFILE_ENABLE`) for
  per-thread accumulated CPU time — read via `tx_thread_execution_time_get()` at the
  bracket boundaries; the delta is CPU time excluding preemption.
- Override the **`TX_THREAD_STATE_CHANGE`** macro (the direction the closed
  [ThreadX PR #429](https://github.com/eclipse-threadx/threadx/pull/429) was steered
  toward) to timestamp ready→running latency and preempted intervals per thread.

The OSAL exposes these behind a stable seam (e.g. `osal.thread_cpu_time_us()`,
`osal.preempt_us()`), so loom's bracket recovers CPU time on ThreadX while staying a
no-op (response == CPU) on a polled bare-metal core.

> Granularity: FBs within a partition are cooperatively scheduled inside **one** thread,
> so the kernel sees the *partition/thread*, not each handler. Per-handler timing comes
> from the loom bracket; the kernel profile corrects for preemption **of the thread**
> during that bracket. loom owns intra-partition timing; the kernel owns
> inter-thread/ISR preemption.

## Recording: per-core SPSC buffers

Two report styles, both fed by the per-handler stats:

1. **Live stats** (cheap, continuous) — periodically push a compact per-handler frame
   (HandlerStat, below). A live gauge; aggregates, not every invocation.
2. **Captured trace** (detailed, on-demand) — a fixed buffer of per-invocation records.

Each `Scheduler` owns its **own** trace buffer, written **only** by that core's loop —
**one writer per buffer**, so it never violates the SPSC/IOC isolation invariant. There
is **no** single shared buffer that multiple cores write (that would need locks and could
corrupt record order). A collector on the bus core reads each per-core buffer (over an
IOC channel, or directly since a stopped buffer is immutable) and streams it out; records
carry the global `handler_id`, so cores never need a shared index.

**Capture modes**: *one-shot* (fill then stop — "trigger, let it fill, read it out") or
*ring* (keep the last N, freeze on a trigger — "capture the moment it overran").
One-shot is the first cut. A build-time-sized buffer (e.g. 4096 records = 32 KB/core) in
a reserved RAM region, no alloc.

## Wire formats

Fixed 8-byte frames on classic CAN; on CAN-FD one 64-byte frame packs up to 8 of the
per-handler records/stats. All little-endian.

**HandlerStat** — the unsolicited live-stats push (one handler per classic frame):

```
b0    handler_id  (u8, global)
b1    flags       (bit0 overran | bit1 preempted | bit2 saturated)
b2-3  last_us     (u16)          response time of the last invocation
b4-5  max_us      (u16)          max since last reset
b6-7  count_delta (u16)          invocations since the previous stat frame
```

**TraceCmd** — host → target (`cmd_id`):

```
b0    opcode          1 arm | 2 start | 3 stop | 4 reset | 5 set_push | 6 dump | 7 status
b1    arg0            set_push kind (0 stats | 1 records) / capture mode
b2-3  period_ms       (u16) for set_push
b4    handler_filter  0xFF = all, else a handler_id
b5-7  reserved
```

**TraceRsp** — target → host (`rsp_id`), one per cmd:

```
b0    opcode_echo
b1    result          0 ok, else error code
b2    state           0 idle | 1 armed | 2 capturing | 3 full
b3-4  records_used    (u16)
b5-6  capacity        (u16)
b7    core
```

**Record** — one handler invocation in the buffer (8 B):

```
b0    handler_id  (u8, global)
b1    flags       (bit0 overran | bit1 preempted | bit2 first-run | bit3 saturated)
b2-5  start_us    (u32)   relative to capture start
b6-7  cpu_us      (u16)   saturating; = response time on a no-IRQ bare-metal core
```

On a **preemptive** target, drawing the preempted gap needs both response and CPU time,
so a preemptive build widens the record to carry `response_us` too (12 B) or emits a
separate preemption event; the base bare-metal record stays 8 B. A bulk **dump** is a
small header (manifest hash, capture-start epoch, `records_used`, core) followed by
`records_used` records, sent as one **ISO-TP** block.

## Time representation

- **Unit: microseconds**, normalized at the measurement boundary, so the wire format is
  identical across host (`CLOCK_MONOTONIC`), bare-metal (DWT cycles ÷ CPU-MHz), and
  ThreadX (profile ticks → µs). Same number means the same thing everywhere (parity).
- **Durations: `u16` µs** (0..65.535 ms), **saturating** — a handler taking longer is
  pathological and sets the `saturated` flag rather than wrapping.
- **Capture-relative timestamps: `u32` µs** (0..~71.6 min per capture).
- **Resolution: 1 µs.** A sub-µs handler reads 0 µs (negligible load); if finer is ever
  needed, the manifest can carry a `time_unit` scale (e.g. 0.1 µs) both ends honour.
- The manifest carries each handler's `period_us` (for jitter/deadline analysis) and the
  time unit, so the host needs nothing from the wire but the raw counts.

## Control & read-out over CAN

Config-declared **cmd/rsp** for control (**not** UDS), **unsolicited push** for the live
case, and **ISO-TP** — a given in the stack — as the raw transport for the bulk dump (no
UDS service layer, DIDs, or RoutineControl).

```toml
[trace]
bus     = "can0"
cmd_id  = 0x7E2   # host -> target: control
rsp_id  = 0x7E3   # target -> host: ack + status
push_ms = 1000    # optional: push HandlerStat every 1 s with no request (0 = off)
```

Push is enabled by a `set_push` cmd *or* from config at boot (so a target streams stats
with no host present — handy on a bench). E2E/SecOC can wrap any of these frames exactly
as COM does.

## Visualization (what a tool draws)

The record + manifest are shaped to feed these views (blobly_net, phase P4):

- **Swimlane / Gantt timeline** — the primary view: one lane per core (handlers stacked,
  or one lane each), every Record a bar at `start_us` of width `cpu_us`; gaps are idle.
  `handler_id → manifest` gives the lane, colour, and name. This is *who ran when*.
- **Load reconstruction** — sum `cpu_us` per core per window → re-derive the CpuLoad /
  LoadDetail curves straight from the trace, a cross-check on the live figures.
- **Period / jitter histogram** — per handler, the spread of actual period (Δ`start_us`)
  vs the manifest `period_us` shows scheduling jitter; the spread of `cpu_us` shows
  typical vs worst-case execution time.
- **Overrun / deadline markers** — Records with `cpu_us > period_us` or the `overran`
  flag get red marks; ties the timeline back to LoadDetail's overrun count.
- **Preemption view (ThreadX)** — where `response_us > cpu_us`, draw the preempted
  interval (thread ready but not running). Needs the response/CPU split, i.e. the wider
  preemptive record.

Live HandlerStat frames drive gauges/sparklines (last/max/count per handler); the
captured trace drives the timeline and histograms.

## Phasing

1. **P1 — loom per-handler timing + unsolicited HandlerStat push** (bare-metal; response
   time = CPU on the polled core). **Develop and verify on host/vcan first** (portable
   FBs, host codegen), then cross-check on the H735. `REQ-TRACE-001/002`.
2. **P2 — captured per-core buffer + cmd/rsp control + ISO-TP dump** (one-shot).
   `REQ-TRACE-003/004`.
3. **P3 — ThreadX preemption** (execution-profile kit + state-change hook → CPU time,
   preemption interval). `REQ-TRACE-005`.
4. **P4 — blobly_net**: load the manifest, decode records, render the timeline / jitter /
   preemption views above.

## Proposed requirements (draft)

Derive `SYS-REQ-OBS-001` (or a new `SYS-REQ-OBS-002` "handler-level runtime
observability"), ASIL QM. Draft until agreed + a verification is linked, so they don't
mark anything covered prematurely:

- **REQ-TELEM-005** — the ECU shall transmit the multi-window load + overrun count as a
  CAN message (the LoadDetail frame). *(implemented target-only; pending host support /
  sign-off, so not yet in `requirements/telemetry.toml`.)*
- **REQ-TRACE-001** — the scheduler shall measure each handler's execution time
  (last/max/mean) and invocation count. *(loom bracket; unit-testable)*
- **REQ-TRACE-002** — each handler shall have a build-stable, globally-unique identity
  resolvable to its configured name without runtime string exchange. *(manifest)*
- **REQ-TRACE-003** — the ECU shall capture a time-ordered trace of handler invocations
  into a fixed per-core buffer, single-writer, and stop when the buffer is full.
- **REQ-TRACE-004** — capture shall be controllable via a configurable command/response
  protocol; trace data shall be readable over the bus (bulk via ISO-TP) and the target
  shall optionally push trace data unsolicited at a configured rate. *(cmd/rsp + push +
  ISO-TP; not UDS)*
- **REQ-TRACE-005** — where the kernel is preemptive, reported handler CPU time shall
  exclude time the thread was preempted. *(ThreadX profile kit)*

## Open decisions

1. **Identity**: shared generated manifest (recommended) vs runtime announce.
2. **Control/transport**: **decided** — config cmd/rsp (not UDS), unsolicited push, ISO-TP
   for the bulk dump.
3. **Capture mode first**: one-shot fill-and-stop (recommended) vs freeze-the-ring.
4. **Record width**: 8 B (bare-metal) / 12 B (preemptive, carries `response_us`) — good?
5. **Where P1 runs first**: host/vcan (recommended, faster loop) then H735.
