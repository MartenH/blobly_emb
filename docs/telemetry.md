# Runtime observability: processor load + thread tracing

The stack observes its **own** runtime and ships it over CAN, so a running ECU can be
watched live in any CAN tool (candump, or the blobly_net GUI decoding it via DBC) — no
`/proc`, no external profiler, no debug probe.

Two layers, from cheap-and-always-on to detailed-and-on-demand:

1. **Processor load** — a small, continuous per-core load percentage (implemented).
2. **Thread tracing** — *which thread ran when* on each core, captured into a buffer and
   read out on command, **optionally** with per-`fb.handler` detail *inside* each thread.

## Threads and fb.handlers — the two trace levels

A **thread** is the OS scheduling unit: on ThreadX a partition runs as one thread, and it
is where the core's time is actually spent and where preemption happens. A thread runs many
**fb.handlers** — each an `[[fb.handler]]`, the functions loom dispatches via
`sched.every(...)` — which are the fine-grained work *inside* a thread. The trace therefore
has two levels, and RAM is finite, so the level is a configured (or read-out-time) trade:

- **Thread trace (coarse)** — one small event per thread run / context switch. Few bytes
  per event, so a fixed buffer spans a **long** window: the big picture of who had the core.
- **Thread + fb.handler trace (fine)** — adds each fb.handler run within the thread. Many
  more events, so the same RAM spans a **shorter** window: zoom in on what a thread did.

(On a fully-cooperative core a partition = one thread that runs its fb.handlers back-to-back,
so the coarse level is nearly flat there; it earns its keep on a **preemptive** target with
several threads per core, where it shows who actually held the core.)

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

# Part 2 — Thread tracing (design)

Processor load answers *"how busy is the core?"*. This layer answers *"where does the
time go?"* — first at the **thread** level (who held the core, and the switches between),
then, when you need it, drilling into the **fb.handlers** inside a thread (which one blew
its budget, scheduling jitter, preemption). Nothing here is built config-driven yet; this
is the shape before the requirements and code.

## Threads are declared in `ecu.toml`

The trace needs threads to be first-class, so `ecu.toml` gains a thread level (today a
partition is an *implicit* single thread). A **partition** (one MPU domain, pinned to a
core) declares one or more **threads** (each a ThreadX thread with a priority), and each
**fb.handler** names the thread it runs on:

```toml
[[partition]]
name = "ctrl"
core = 1
  [[partition.thread]]
  name     = "fast"
  priority = 10          # ThreadX priority (lower = higher); preemption between threads
  [[partition.thread]]
  name     = "slow"
  priority = 20

[[fb]]
name      = "SpeedMonitor"
partition = "ctrl"
  [[fb.handler]]
  name      = "on_10ms"
  period_ms = 10
  thread    = "fast"     # runs on ctrl's "fast" thread
```

Every **partition MUST declare at least one thread** — there is no implicit default; a
partition always has an explicit thread set. An **fb.handler runs on a thread of its
partition**: `thread` is optional when the partition has exactly one thread (it defaults to
that one) and **required** when the partition declares several. Multiple threads per core is
what makes the coarse thread trace earn its keep (preemption by priority → who actually held
the core). loom2v rejects a partition with no thread, or an fb.handler whose `thread` isn't
one of its partition's threads.

## Identity: a generated manifest (threads + fb.handlers)

loom2v emits a **manifest** with two tables — one for threads, one for fb.handlers — each
with a **globally unique** id across all partitions (not a per-scheduler index, which would
collide). For `overspeed` (partitions `sense` + `ctrl`, one thread each):

```
# threads: thread_id = the b0 in every thread-trace record
thread_id | name  | core
0         | sense | 0
1         | ctrl  | 1

# fb.handlers: handler_id = the b0 in every fb.handler-detail record
handler_id | thread | core | fb          | handler | period_us
0          | sense  | 0    | SpeedFilter | on_10ms | 10000
1          | sense  | 0    | WheelWatch  | on_10ms | 10000
2          | ctrl   | 1    | SpeedMonitor| on_10ms | 10000
3          | ctrl   | 1    | LampDriver  | on_20ms | 20000
```

The target tags each record with its id — a `u8` **thread_id** at the coarse level, a `u16`
**handler_id** at the fine level (a `u16` because a real ECU can have far more than 256
fb.handlers); blobly_net resolves it to a name / core / period from the **same manifest** it
loads next to the DBC. So the target never sends strings and the map can't drift — one
source of truth.

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
corrupt record order). Read-out is **IOC-mediated, never a direct cross-core read**: the
producing partition hands its stopped buffer (or successive chunks of it) to the bus core
over an `osal.ioc_*` channel, and the bus core streams from that. This holds the "cross-
core data flows only through IOC" invariant — on an MPU/ThreadX target the bus core has
no mapping to another partition's RAM, and immutability-after-stop doesn't grant one.
Records carry the global `handler_id`, so cores never need a shared index.

**Capture modes** — the per-core buffer depth is **configured** (`[trace] buffer_records`),
emitted as a static array at build (no runtime alloc); the value trades RAM for trace
depth (e.g. 4096 records × 8 B = 32 KB/core):

- **one-shot** — fill then stop; "trigger, let it fill, read it out." The first cut.
- **ring / FIFO** — record continuously, overwriting the oldest; on a **trigger** freeze
  with a **pre/post split** (keep `pre` % of the ring from *before* the trigger plus the
  rest from after, then stop). This is the flight recorder — see Triggers.

## Triggers — freeze the ring (software, HW-ready)

The ring's value is the **trigger**: record continuously, and when a configured condition
fires, freeze with the history *around* it. Point it at a fault/DTC flag and you keep the
last N handler invocations that led up to it — a black-box recorder read out over CAN
with **no debug probe attached**.

**Software trigger, no debug HW.** The trigger is a software condition, *not* a DWT /
CoreSight watchpoint. That keeps it portable (identical in sim and on any target), keeps
the "no probe" property, and doesn't burn a scarce hardware comparator a live debugger
wants. Because the stack is config-driven, the natural thing to watch is a **signal**,
not a raw address:

- **signal** (recommended) — loom2v generates every signal write, so it emits the trigger
  check **at the write site**: event-driven, catches *every* change, zero polling cost,
  portable host↔target.
- **address** (advanced) — poll a **partition-local** address (a `volatile` variable in
  the triggering partition's *own* memory) each cycle against the condition. Strictly
  bounded to local/owned memory — **never** an arbitrary or cross-partition address,
  which would break the IOC-only / memory-protection invariants (a partition can't read
  another's RAM). Costs a poll and can miss a value set-and-cleared between checks.
  Watching arbitrary or another partition's memory is *only* the reserved `hw` (DWT)
  source, itself bounded by the target's memory protection.

**One seam, pluggable sources.** The ring exposes a single entry point —
`trace_trigger()` (freeze after the post-trigger count). Whatever detects the condition
just calls it, so a future **hardware watchpoint** source (target-only DWT comparator,
zero-overhead, catches the exact access) drops in behind the same seam with **no change**
to the ring, the capture state machine, or the CAN protocol. The config is forward-
compatible for it:

```toml
[trace.trigger]
source = "signal"    # signal | address | hw   (hw reserved -> DWT watchpoint, later)
signal = "FaultFlag"
when   = "== 1"      # ==, !=, >, <, changed, & mask
pre    = 75          # % of the ring kept before the trigger (rest is post-trigger)
```

`source = "hw"` is a **reserved** key in this design — nothing parses `[trace]` config
yet (no trace codegen exists today); when the config is implemented, `hw` is accepted and
routed to the DWT backend. The point is that the *seam and the config shape* are designed
now, so adding it later is a backend, not a redesign — "preparing for" the hardware route
without pulling debug HW into the build.

**Prior art** (this is a well-trodden pattern): ARM CoreSight **ETB + trigger** and the
Cortex-M **DWT watchpoint** (the hardware route we're deliberately *not* taking yet);
**Percepio Tracealyzer** snapshot mode and **SEGGER SystemView** (software RTOS-trace
rings, freeze + dump); a **logic analyzer / DSO** pre/post-trigger buffer (the mental
model); and — most domain-relevant — automotive **XCP (ASAM MCD-1)** event-triggered DAQ,
which measures ECU memory over the bus on a condition. We're building the software,
config-driven version of that, on the CAN the ECU already has.

## Wire formats

Fixed 8-byte frames on classic CAN; on CAN-FD one 64-byte frame packs several of the
8-byte HandlerStats / bare-metal Records (up to 8, fewer with any header). The 12-byte
preemptive Record packs at most 5 per FD frame. All little-endian.

**HandlerStat** — the unsolicited live-stats push (one fb.handler per classic frame). The
`handler_id` is a `u16` here too; to keep the frame 8 bytes the live `count_delta` shrinks
to a saturating `u8` (a rough live rate — the dump carries exact counts):

```
b0-1  handler_id  (u16, LE, global)
b2    flags       (bit0 overran | bit1 preempted | bit2 saturated)
b3-4  last_us     (u16)          response time of the last invocation
b5-6  max_us      (u16)          max since last reset
b7    count_delta (u8, saturating)   invocations since the previous stat frame
```

**TraceCmd** — host → target (`cmd_id`):

```
b0    opcode          1 arm | 2 start | 3 stop | 4 reset | 5 set_push | 6 dump | 7 status
b1    arg0            set_push kind (0 stats | 1 records) / capture mode
b2-3  period_ms       (u16) for set_push
b4-5  handler_filter  (u16) 0xFFFF = all, else a handler_id. handler_id now being a u16,
                      0xFFFF is reserved as the "all" sentinel — ids run 0..0xFFFE (65535
                      fb.handlers, still far more than any real ECU)
b6-7  core_mask       (u16) bit i = core i; one cmd addresses several cores at once
                      (arm/stop/dump/… fan out). 0 = the receiving/default core (core 0),
                      so existing single-core commands keep working unchanged.
```

A **multi-core dump** is one `dump` with several `core_mask` bits set. The bus core owns
the fan-out: for each selected core it pulls that core's frozen buffer **over IOC** (never
a direct cross-core read — the recording invariant), sends that core's TraceRsp, then
streams its self-describing ISO-TP block (block-header record + records). One command,
N per-core blocks, in ascending core order.

**TraceRsp** — target → host (`rsp_id`), one per cmd:

```
b0    opcode_echo
b1    result          0 ok, else error code
b2    state           0 idle | 1 capturing | 2 full | 3 frozen
b3-4  records_used    (u16)
b5-6  capacity        (u16)
b7    core
```

Records come in **two levels**. A buffer holds one level, so its cell size is uniform (one
no-alloc array). The level is configured (or chosen at read-out).

### Coarse — thread trace (4-byte record)

The primary "who held the core" level. One record per context switch: the thread now
running, **why** the switch happened (so preemption is explicit, not guessed), and the time
since the previous record. Kept to 4 bytes by **delta**-encoding the time — switches are
frequent, so a `u16` µs delta covers the gap while the *window is unbounded* (the host
accumulates deltas):

```
b0    to_thread  (u8)         the thread now running
b1    reason     (u8)         what happened to the OUTGOING thread (its fate):
                              0 preempted | 1 blocked | 2 yielded | 3 exited | 255 time-extend
b2-3  delta_us   (u16, LE)    time since the previous record (`time_unit`-scaled)
```

The host reconstructs the timeline by accumulating `delta_us`, and reads each record as
*"`to_thread` ran until the next switch"*. **`reason` is the preemption signal**: `preempted`
means the outgoing thread is still ready and will resume (a higher-priority thread took the
core); `blocked`/`yielded`/`exited` mean it gave up voluntarily. If a thread runs longer than
one `u16` delta (~65 ms at 1 µs, longer with a coarser `time_unit`) with no switch, the target
emits a `255 time-extend` record (a `+65535`-unit tick, `to_thread` unchanged) so the delta
never overflows. `from_thread` is implicit — the previous record's `to_thread`.

### Fine — thread + fb.handler trace (8-byte records)

Adds the fb.handler runs *inside* each thread (and, on a preemptive target, explicit
switch events). A fixed 8-byte cell, three kinds told apart by two **kind** bits in the
`flags` byte — which is **`b0` in every kind** so a decoder always finds it at a fixed
offset (`bit7 = thread-switch`, `bit6 = block-header`; both clear = an fb.handler run).
`handler_id` is a `u16` (a real ECU can have >256 fb.handlers, e.g. `scale`); the timestamp
is a `u24` (16.7 s at 1 µs, longer via `time_unit`) — generous for the fine level's short
window and one width across kinds.

*fb.handler-run record* (kind = 0 — one invocation):

```
b0    flags       (bit0 overran | bit1 preempted | bit2 first-run | bit3 saturated; kind = 0)
b1-2  handler_id  (u16, LE, global)   >256 fb.handlers OK
b3-5  start_us    (u24, LE)   relative to capture start
b6-7  cpu_us      (u16)       saturating; = response time on a no-IRQ bare-metal core
```

*Thread-switch record* (kind = `bit7`) — the explicit context switch, interleaved so a fine
dump is one timeline of *which fb.handler ran* and *the thread switches between them*
(`thread_id` stays `u8` — threads are few). No `from_thread`: it's the currently-running
thread the decoder already tracks (the previous switch's `to_thread`, or the thread of the
last fb.handler-run record):

```
b0    flags       (bit7 set)
b1    to_thread   (u8)    the thread now running
b2    reason      why the OUTGOING thread stopped (its fate — the preemption signal):
                  0 preempted (still ready → resumes later) | 1 blocked | 2 yielded | 3 exited
b3-5  start_us    (u24, LE)   relative to capture start — when the switch happened
b6-7  reserved
```

`reason` always describes the **outgoing** thread (`to_thread` runs *because* the previous
thread `preempted`/`blocked`/`yielded`/`exited`). There's no `resume` reason — a preempted
thread resuming is just its `thread_id` reappearing as `to_thread`.

**Interrupts are not threads.** An ISR firing is *not* a thread switch — the same thread
resumes after it; the ISR only steals CPU time (the response-vs-CPU-time split above). So
`thread_id` stays `u8` (threads really are few — a partition has a handful), and ISRs are
kept out of that id space entirely: they can't fit anyway (a big MCU has **thousands** of
interrupt vectors, way past 256). Interrupts are handled two ways, neither touching
`thread_id`: (1) **as time** — the running thread's CPU time excludes ISR time, via the
ThreadX profile kit's separate ISR bucket; (2) optionally, a **per-vector ISR trace** with a
wide **`u16` irq_id** (its own record kind / buffer), for when you need to see which
interrupt fired and for how long. That's a separate, opt-in level — the thread trace itself
never carries interrupt ids.

*Block-header record* (kind = `bit6`) — one leading entry per core in a multi-core dump so
each ISO-TP block is **self-describing** (split the stream by core without correlating to
the rsp). `flags` at `b0` here too:

```
b0    flags       (bit6 set)
b1    core        (u8)
b2-5  count       (u32, LE)   records that follow in this block
b6-7  reserved
```

The **coarse** level has no kind byte (its 4 bytes are all thread_id + reason + delta), so
it frames a multi-core dump **positionally**: each per-core block is a 4-byte header
(`b0 = core`, `b1-3 = count` u24) followed by exactly `count` thread records, then the next
header. A single-core coarse dump has no header — the TraceRsp's `records_used` is the count.
(One level per buffer, so coarse and fine records never mix.)

A **single-core dump** is just that core's `count` records as one **ISO-TP** block — the
TraceRsp already names the core, so no header is needed (this is what the single-core
`trace_demo` sends). The **block-header** record is added only in a **multi-core dump**
(several `core_mask` bits): there the blocks share one `record_id` stream, so each is
prefixed with a header naming its core + count to keep it self-describing. So a decoder
that may receive multi-core dumps checks `flags` bit6 and, when set, starts a new core
block; a single-core stream has no header and decodes straight as records.

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
bus            = "can0"
cmd_id         = 0x7E2   # host -> target: control
rsp_id         = 0x7E3   # target -> host: ack + status
push_ms        = 1000    # optional: push HandlerStat every 1 s with no request (0 = off)
buffer_records = 4096    # per-core capture depth, 1..65535 (see Recording) — RAM vs depth
                         # capped at 65535: records_used/capacity are u16 in TraceRsp
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
- **Preemption / swimlane view (ThreadX)** — the thread-switch records give the actual
  context-switch timeline: each is a `from_thread → to_thread` edge at `start_us`, so a
  tool draws one lane per thread (= partition) and shades the interval a thread is switched
  out. This is exact (drawn from the switch edges), not inferred from a response/CPU split.
  `reason` colours the edge (preempt vs voluntary block vs ISR).

Live HandlerStat frames drive gauges/sparklines (last/max/count per handler); the
captured trace drives the timeline and histograms.

## Phasing

1. **P1 — loom per-handler timing + unsolicited HandlerStat push** (bare-metal; response
   time = CPU on the polled core). **Develop and verify on host/vcan first** (portable
   FBs, host codegen), then cross-check on the H735. `REQ-TRACE-001/002`.
2. **P2 — captured per-core buffer + cmd/rsp control + ISO-TP dump** (one-shot).
   `REQ-TRACE-003/004`.
3. **P3 — ring/FIFO capture + software trigger** (freeze-the-ring, pre/post split; signal
   trigger event-driven at the write site, address poll optional; the pluggable
   `trace_trigger()` seam with `source = "hw"` reserved). `REQ-TRACE-006/007`.
4. **P4 — ThreadX preemption + thread-switch (swimlane) capture** (execution-profile kit
   for CPU time; the `TX_THREAD_STATE_CHANGE` hook feeds thread-switch records into the
   same ring, so a dump carries the context-switch timeline). `REQ-TRACE-005/008`.
5. **P4b — multi-core dump-in-one-command** (`core_mask` fan-out; per-core self-describing
   ISO-TP blocks, gathered over IOC). `REQ-TRACE-009`.
6. **P5 — blobly_net**: load the manifest, decode records, render the timeline / jitter /
   preemption / swimlane views above.

> **Host vs target.** The record kinds, codecs, `core_mask` control, and multi-core dump
> fan-out are portable and verified on host/vcan (multi-core = several loom schedulers in
> one process, one bus loop). The **source** of thread-switch records is the ThreadX
> `TX_THREAD_STATE_CHANGE` hook, which has no equivalent on the cooperative host — so the
> host harness injects synthetic switch records to exercise the codec/dump end-to-end,
> exactly as the DWT `hw` trigger is seam-only until silicon.

## Requirements

The `REQ-TRACE-*` here derive `SYS-REQ-OBS-002` "handler-level runtime observability";
`REQ-TELEM-005` below derives `SYS-REQ-OBS-001` (processor **load** observability — it's a
load frame, not handler runtime). All ASIL QM. **REQ-TRACE-001** (measurement) is agreed +
verified and **REQ-TRACE-002** (identity) is draft — both now in
`requirements/trace.toml`. The ones below are still **proposed (draft in this doc)** until
their phase lands, so nothing is marked covered prematurely:

- **REQ-TELEM-005** *(→ SYS-REQ-OBS-001, load)* — the ECU shall transmit the multi-window
  load + overrun count as a CAN message (the LoadDetail frame). *(implemented target-only;
  pending host support / sign-off, so not yet in `requirements/telemetry.toml`.)*
- **REQ-TRACE-003** — the ECU shall capture a time-ordered trace of handler invocations
  into a per-core buffer whose depth is **configured** (`buffer_records`, 1..65535 to fit
  the u16 status fields, a static array, no runtime alloc), single-writer, and stop when
  the buffer is full.
- **REQ-TRACE-004** — capture shall be controllable via a configurable command/response
  protocol; trace data shall be readable over the bus (bulk via ISO-TP) and the target
  shall optionally push trace data unsolicited at a configured rate. *(cmd/rsp + push +
  ISO-TP; not UDS)*
- **REQ-TRACE-005** — where the kernel is preemptive, reported handler CPU time shall
  exclude time the thread was preempted. *(ThreadX profile kit)*
- **REQ-TRACE-006** — the ECU shall support a ring/FIFO capture mode that records
  continuously and, on a trigger, freezes with a configurable pre/post-trigger split.
  *(flight recorder)*
- **REQ-TRACE-007** — capture shall be freezable by a configurable software trigger — a
  signal condition, or an address condition on **partition-local memory only** — through
  a single trigger seam that admits additional sources (incl. a future hardware
  watchpoint for arbitrary memory) without redesign. *(no debug HW; no cross-partition
  reads)*
- **REQ-TRACE-008** — where the kernel is preemptive, the ECU shall capture thread
  (partition) context switches into the same per-core trace buffer as handler
  invocations, each recording the from/to thread, timestamp, and reason, so a dump yields
  the context-switch (swimlane) timeline. *(thread-switch record kind; ThreadX
  state-change hook the source, no-op on a cooperative core)*
- **REQ-TRACE-009** — a single control command shall address several cores at once (a core
  bitmask); a multi-core dump shall stream one self-describing block per selected core,
  each gathered from its owning core over IOC (no direct cross-core buffer read).

## Open decisions

1. **Identity**: shared generated manifest (recommended) vs runtime announce.
2. **Control/transport**: **decided** — config cmd/rsp (not UDS), unsolicited push, ISO-TP
   for the bulk dump.
3. **Capture modes**: **decided** — one-shot (P2) then ring/FIFO + trigger (P3), same
   records feed both.
4. **Buffer depth**: **decided** — configured per core (`[trace] buffer_records`), a
   static array at build; the value trades RAM for trace depth.
5. **Trigger**: **decided** — software, no debug HW: a signal condition checked at the
   generated write site (recommended), or an address poll (advanced); one `trace_trigger()`
   seam with `source = "hw"` (DWT) reserved for later.
6. **Record width**: **decided** — one homogeneous **8 B** cell for every kind; a
   preemptive build does *not* widen the record but adds a **thread-switch record kind**
   (kind bits in `flags`) whose switch edges give the preemption timeline directly. Keeps
   the ring a single no-alloc array and one dump format.
7. **Multi-core dump framing**: **decided** — `core_mask` in TraceCmd fans out; per-core
   self-describing ISO-TP blocks (block-header record + records), in ascending core order,
   each pulled over IOC by the bus core.
