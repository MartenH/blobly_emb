# Runtime observability: processor load + task/FB runtime tracing

The stack observes its **own** runtime and ships it over CAN, so a running ECU can be
watched live in any CAN tool (candump, or the blobly_net GUI decoding it via DBC) — no
`/proc`, no external profiler, no debug probe.

Two layers, from cheap-and-always-on to detailed-and-on-demand:

1. **Processor load** — a small, continuous per-core load percentage (implemented).
2. **Task & FB runtime tracing** — per-task/per-FB execution timing, optionally
   preemption-aware, captured into a buffer and read out on command (design below).

---

# Part 1 — Processor load (implemented)

Each `Scheduler` brackets the time it spends in `run()` and rolls it into a duty cycle
over several windows at once — `load_permille_100ms/1s/10s()`, 0..1000. This is
*handler work / wall clock*: the useful-work fraction (it excludes poll/sleep overhead,
so it reads a little lower than a `top`-style figure). `REQ-TELEM-001`, `REQ-TELEM-003`.

The generated telemetry tx reports it on the bus:

- **`CpuLoad` (0x7E0)** — one byte per core = load percent over the 1 s window
  (`comm/telem.encode_cpuload`). `REQ-TELEM-002`.
- **`LoadDetail` (0x7E1)** — one core's load over the 100 ms / 1 s / 10 s windows plus
  its per-period **overrun** count (`encode_loaddetail`). The 100 ms window surfaces
  bursts the 1 s figure averages away; a non-zero overrun byte means commanded work
  exceeded the core's capacity. `REQ-TELEM-004`, `REQ-TELEM-005`.

```toml
[telemetry]
enabled   = true
bus       = "can0"
id        = 0x7E0    # CpuLoad
detail_id = 0x7E1    # LoadDetail (optional; omit to send only CpuLoad)
period_ms = 500
```

On the host the tx is a spawned thread summing per-scheduler load by core; on the
bare-metal single-core target (`[target] baremetal`) it is sent inline from the
generated `run()` loop, reading `load_permille*()` directly. The load is only valid
when the loop yields **genuine idle** between passes (the fixed-tick pacing) — an
unpaced free-running loop would read a bogus ~50 % floor.

---

# Part 2 — Task & FB runtime tracing (design)

Processor load answers *"how busy is the core?"*. This layer answers *"where does the
time go?"* — the runtime of each individual task/FB, so you can find the handler that
blew its budget, see jitter, and catch preemption. Nothing here is built yet; this is
the agreed shape before the requirements and code.

## What is a "task"?

A **task** is a schedulable unit = one `[[fb.handler]]`. It is already in `ecu.toml`;
it just isn't spelled `[[task]]`. For h735_app the task set is `Governor.on_100ms`,
`Load.on_1ms`, `Heartbeat.on_100ms` — exactly the three `sched.every(...)` entries loom
registers. So tracing needs no new config concept, only a **stable identity** for each
handler.

### Identity: a generated manifest, not a runtime announce

Because everything is generated from `ecu.toml`, the task set is known at build time on
**both** ends. loom2v emits a **task manifest** — a small generated table:

```
task_id | partition | fb        | handler   | period_us | core
0       | app       | Governor  | on_100ms  | 100000    | 0
1       | app       | Load      | on_1ms    | 1000      | 0
2       | app       | Heartbeat | on_100ms  | 100000    | 0
```

`task_id` is the index in loom's scheduler table (stable for a given build). The target
tags every trace record with `task_id` only (1 byte, cheap); blobly_net resolves
`task_id → name` from the **same manifest** it loads next to the DBC. So the target
never has to send strings, and the map can't drift — it's the same source of truth.

> **Decision — shared manifest over runtime announce.** A self-describing target (send
> a "task table" frame at startup) is more robust to a host/target manifest mismatch
> and supports hot-attach, but it costs bus traffic, a string protocol, and a second
> identity path. Recommendation: **shared manifest** (config-driven, matches the rest
> of the stack); add an *optional* announce frame later only if field mismatches bite.

## What we measure: two clocks

Every task invocation has two useful durations, and they differ **only under
preemption**:

- **Response time** (wall clock): `now` after the handler − `now` before. Includes any
  time the task was preempted mid-run. This is what a deadline cares about, and it is
  exactly what a loom bracket already measures.
- **CPU time** (execution): response time **minus** time spent preempted. This is the
  true cost of the task on the core.

On the **cooperative loom** (bare-metal, no RTOS) an FB handler runs to completion and
is never preempted by another FB — so **response time == CPU time**, and a simple loom
bracket is exact. Preemption enters only via (a) ISRs, or (b) on ThreadX, the partition
thread being preempted by a higher-priority thread. The design measures response time
everywhere and *additionally* recovers preemption where a preemptive kernel is present.

## Mechanism

### loom (cooperative, all targets) — per-handler bracket

`loom.Scheduler.run()` already times the whole pass. Extend it to bracket **each**
dispatched handler and fold the duration into a per-task stat:

```
for each due task i:
    t0 = now()
    handlers[i](ctx[i])
    dt = now() - t0
    stat[i].last = dt; stat[i].max = max(max, dt); stat[i].count++; stat[i].total += dt
```

This is fixed-memory (one `TaskStat` per scheduler slot, no alloc) and gives
last/max/mean execution time and invocation count per FB. On bare-metal this is the
exact CPU time. Cost: two `now()` reads per handler dispatch — negligible with the DWT
cycle counter.

### ThreadX (preemptive) — profile kit + state-change hook

When partitions run as ThreadX threads, the partition thread can be preempted (ISRs,
higher-priority threads). To get true CPU time and see preemption:

- Enable ThreadX's **execution-profile kit** (`TX_EXECUTION_PROFILE_ENABLE`) for
  per-thread accumulated CPU time — read via `tx_thread_execution_time_get()` at the
  bracket boundaries; the delta is CPU time excluding preemption.
- Override the **`TX_THREAD_STATE_CHANGE`** macro (the direction the closed
  [ThreadX PR #429](https://github.com/eclipse-threadx/threadx/pull/429) was steered
  toward) to timestamp ready→running latency and preempted intervals per thread.

The OSAL exposes these behind a stable seam (e.g. `osal.thread_cpu_time_us()`,
`osal.preempt_count()`), so loom's bracket subtracts preemption to yield CPU time on
ThreadX while staying a no-op (response == CPU) on bare-metal. Task↔thread mapping is
known from the manifest (a partition is one thread today).

> Granularity note: FBs within a partition are cooperatively scheduled inside **one**
> thread, so the kernel sees the *partition*, not each FB. Per-FB CPU time therefore
> comes from the loom bracket; the kernel profile corrects for preemption **of the
> partition thread** during that bracket. That's the right split — loom owns intra-
> partition timing, the kernel owns inter-thread/ISR preemption.

## Recording: the trace buffer

Two report styles, both fed by the same per-task stats:

1. **Live stats** (cheap, continuous) — like LoadDetail, periodically send a compact
   per-task frame: `task_id | last_us | max_us | overrun?`. Good for a live gauge; low
   fidelity (aggregates, not every invocation).
2. **Captured trace** (detailed, on-demand) — a fixed ring/linear buffer of
   per-invocation records:

   ```
   record: task_id (u8) | start_us (u32, rel to capture start) | cpu_us (u16) | flags (u8)
           flags: preempted, overran, first-run, ...   → 8 bytes/record
   ```

   A build-time-sized buffer (e.g. 4096 records = 32 KB) in a reserved RAM region, no
   alloc. **Capture modes**: *one-shot* (fill then stop — the classic "trigger, let it
   fill, read it out") or *ring* (keep the last N, freeze on a trigger — good for
   "capture the moment it overran"). One-shot is the first cut.

## Control & read-out over CAN

Tracing has its **own lightweight command/response** protocol for control — **not** UDS.
The bulk buffer transfer rides **ISO-TP** (which is a given in the stack) for
segmentation, but as the raw transport only: no UDS service layer, no DIDs, no
RoutineControl. And the target can **push unsolicited** so it streams without being
polled ("send me the task times every 1 s").

**Control (cmd → rsp), config-declared frames.** A `[trace]` block names the ids/bus,
like any other frame — nothing hard-coded:

```toml
[trace]
bus     = "can0"
cmd_id  = 0x7E2   # host -> target: control
rsp_id  = 0x7E3   # target -> host: ack + status
push_ms = 1000    # optional: stream live stats every 1 s with no request (0 = off)
```

Opcodes (1-byte + args in the frame): `arm` / `start` / `stop` / `reset`,
`set_push {stats|records, period_ms, task_filter}`, `dump`. Each cmd gets a `rsp`:
opcode echo + result + `state (idle/armed/capturing/full)` + `records_used/capacity`.
Fixed 8-byte (or FD) frames; no segmentation, no service ids.

**Unsolicited push (no request).** Enabled by a `set_push` cmd *or* from config at boot
(so a target streams with no host present — handy on a bench):
- **live stats** — a periodic per-task frame (`task_id | last_us | max_us | flags`), the
  runtime sibling of LoadDetail. The common case; needs no buffer.

**Bulk dump over ISO-TP.** On `dump` (or auto when the buffer is full) the fixed-record
buffer is sent as **one ISO-TP segmented block** — the transport handles multi-frame +
flow control, so there's no bespoke sequence-number scheme. blobly_net reassembles and
decodes the records via the manifest.

E2E/SecOC can wrap any of these frames exactly as COM does, if the data must be
protected.

## Phasing

1. **P1 — loom per-FB timing + unsolicited live-stats push** (bare-metal, exact; no
   preemption). Config-enabled periodic per-task frame, verified on the H735 like the
   load telemetry — no control protocol needed yet. `REQ-TRACE-001/002`.
2. **P2 — captured trace buffer + cmd/rsp control + ISO-TP dump** (one-shot).
   `REQ-TRACE-003/004`.
3. **P3 — ThreadX preemption** (execution-profile kit + state-change hook → CPU time,
   preemption count/latency). `REQ-TRACE-005`.
4. **P4 — blobly_net**: load the task manifest, decode records, render a per-task
   timeline / flame-ish view.

## Requirements this yields (draft)

All derive `SYS-REQ-OBS-001` (or a new `SYS-REQ-OBS-002` "task-level runtime
observability"), ASIL QM, method test/review:

- **REQ-TRACE-001** — the scheduler shall measure each task's execution time
  (last/max/mean) and invocation count. *(loom bracket; unit-testable)*
- **REQ-TRACE-002** — each task shall have a build-stable identity resolvable to its
  configured name without runtime string exchange. *(manifest)*
- **REQ-TRACE-003** — the ECU shall capture a time-ordered trace of task invocations
  into a fixed buffer, and stop capture when the buffer is full. *(one-shot)*
- **REQ-TRACE-004** — capture shall be controllable via a configurable command/response
  protocol; trace data shall be readable over the bus (bulk via ISO-TP) and the target
  shall optionally push trace data unsolicited at a configured rate. *(cmd/rsp + push +
  ISO-TP; not UDS)*
- **REQ-TRACE-005** — where the kernel is preemptive, reported task CPU time shall
  exclude time the task was preempted. *(ThreadX profile kit)*

## Open decisions

1. **Identity**: shared generated manifest (recommended) vs runtime announce.
2. **Control/transport**: **decided** — lightweight config-declared cmd/rsp for control
   (not UDS), unsolicited push for the live case, ISO-TP for the bulk buffer dump.
3. **Capture mode first**: one-shot fill-and-stop (recommended) vs freeze-the-ring.
4. **Record width**: 8 B/record (above) balances fidelity vs buffer depth — good?
5. **Bulk dump on classic CAN vs CAN-FD**: ISO-TP works on both; FD just needs far fewer
   frames. Follow the bus's configured `fd` flag.
