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

### ThreadX (preemptive) — the execution-change-notify hooks

Thread switches and ISRs are captured through ThreadX's **execution-change-notify** hooks —
**not** `TX_THREAD_STATE_CHANGE`. That macro fires on block/unblock/sleep/terminate, *not* on
the running↔preempted transition: a preempted thread stays `TX_READY` (the running thread is
just the `TX_READY` one `_tx_thread_current_ptr` points at), so preemption changes no state
field. The real swap point is the context-switch handler (`_tx_thread_schedule` / the port's
PendSV `__tx_ts_handler`). Build the kernel with **`TX_ENABLE_EXECUTION_CHANGE_NOTIFY`** and
the port assembly calls four functions at exactly the points we need — **we supply them**:

| we implement | kernel calls it from | we do |
|---|---|---|
| `_tx_execution_thread_enter()` | context switch, **after** `_tx_thread_current_ptr` is repointed to the new thread | emit a thread record (`to_thread` = `current_ptr` id, time) |
| `_tx_execution_thread_exit()`  | context switch, **before** `current_ptr` is repointed (still the outgoing thread) | read `reason` off the outgoing thread; close its slot |
| `_tx_execution_isr_enter()`    | `_tx_thread_context_save` (ISR begins)           | pause thread accounting; opt. per-vector `u16 irq` record |
| `_tx_execution_isr_exit()`     | `_tx_thread_context_restore` (ISR ends)          | resume thread accounting |

Both switch hooks take **no arguments** — they read `_tx_thread_current_ptr` (the enter hook
after it points at the incoming thread, the exit hook while it still points at the outgoing
one), so no `from_thread` need be passed.

> **Verified at runtime (not just in source).** Built the stock Cortex-M7 port
> (`ports/cortex_m7/gnu`) with `TX_ENABLE_EXECUTION_CHANGE_NOTIFY` + our four stub hooks and
> ran it under QEMU (`mps2-an500`, 3 threads + 100 Hz SysTick). `thread_enter`/`thread_exit`
> climbed **balanced** (276/276), `isr_enter`/`isr_exit` tracked the tick (90 over ~300 ms =
> 100 Hz), and the enter hook read the correct incoming thread name each time. The exit hook
> firing *before* `current_ptr` is repointed (confirmed in `tx_thread_schedule.S`: the
> `BL _tx_execution_thread_exit` precedes the `_tx_thread_current_ptr` store) is what lets
> `reason` be read from the outgoing thread with no argument passing. The **Linux/POSIX sim
> port does *not* call these hooks** (pthread scheduler, hooks never wired in) — so this
> capture path is Cortex-target-only and must be seam-stubbed on the host.

- **`reason`** comes from the **outgoing** thread's `tx_thread_state` at the switch:
  `TX_READY` → *preempted*; a suspend state → *blocked/yielded* (the suspend kind
  distinguishes); `TX_COMPLETED`/`TX_TERMINATED` → *exited*. No guessing.
- **System Timer Thread.** With the default (non-`TX_TIMER_PROCESS_IN_ISR`) build, ThreadX
  runs a hidden **System Timer Thread** that wakes to expire `tx_thread_sleep`/timers — it
  showed up in the spike as a real scheduled thread. The generated thread manifest must
  reserve an id for it (or the build must set `TX_TIMER_PROCESS_IN_ISR`), else swap records
  reference an unlabelled thread.
- **ISRs** are captured with no per-ISR instrumentation — *provided* the ISR routes through
  `_tx_thread_context_save`/`_tx_thread_context_restore` (a per-Cortex requirement; the port's
  ISR wrappers must be wired). CPU-vs-response time is then the thread's run time minus the
  ISR bucket, computed in these same hooks.
- This needs **only** `TX_ENABLE_EXECUTION_CHANGE_NOTIFY` + our four functions — not the full
  execution-profile kit. That kit is just an alternative *consumer* of the same hooks (it
  `#define`s the notify flag and supplies its own versions); we supply ours instead.

The OSAL exposes this behind a stable seam so the same loom/trace code is a no-op
(response == CPU, no switches) on a polled bare-metal core.

> Granularity: with the thread model above a partition can run **several** threads, so the
> kernel's switch hook *is* the coarse thread trace directly. fb.handler timing *within* a
> thread comes from the loom bracket (`run_profiled`); the kernel owns inter-thread + ISR,
> loom owns intra-thread fb.handler timing.

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

### Coarse — the who-had-the-core timeline (4-byte, type-tagged records)

The compact long-history level: **one time-ordered stream of threads, interrupts, and idle** —
not just thread switches. Every record is **exactly 4 bytes** and **self-describing** — `b0`'s
top 3 bits are a **type**, the low 5 bits an aux field. Time is **delta**-encoded (µs since the
previous record), so the window is unbounded (the host accumulates deltas). One fixed stride →
the ring is trivial and the dump ships the bytes verbatim.

```
b0 = (type << 5) | aux5
 type 0  SWITCH   aux5=reason  b1=to_thread(u8)   b2-3=delta_us(u16 LE)   a thread starts running
 type 1  ISR      aux5=0       b1=isr_id(u8)      b2-3=delta_us(u16 LE)   an interrupt starts running
 type 2  ISR_END  aux5=0       b1=0               b2-3=delta_us(u16 LE)   the innermost ISR returns
 type 3  IDLE     aux5=reason  b1=0               b2-3=delta_us(u16 LE)   no thread ready — core idle
 type 4  TICK     aux5=0       b1-3=delta_us(u24 LE)                      pure time advance (bridges >65 ms)
```

- **`delta_us` names the PREVIOUS state's duration.** A record marks an event at time `T`; its
  delta is `T − T_prev`, and the state active during `[T_prev, T)` is whatever the *previous*
  record established. "task ran 300 µs then an ISR fired" is the **ISR** record carrying Δ=300.
- `reason` (SWITCH/IDLE): what happened to the thread that just stopped —
  `0 preempted | 1 blocked | 2 yielded | 3 exited`. `preempted` = still ready, resumes later;
  the rest = voluntary. `from_thread` is always implicit (the decoder tracks the current thread).
- **ISRs are a `u8 isr_id`** here — a manifest-assigned id (like `thread_id`), not the raw
  vector, to stay 4 bytes. The manifest maps `isr_id → vector + name`; an unmapped interrupt
  records as `0xFF` ("other"). Full raw **`u16` vectors** live at the **fine** level.
- **`TICK`** bridges gaps longer than one `u16` delta (~65 ms at 1 µs) — e.g. a long idle — so
  a delta never overflows and the current state is preserved.
- A decoder walks the stream keeping *current thread* + an *ISR-nesting stack*: SWITCH sets the
  thread, ISR pushes, ISR_END pops back, IDLE clears.

#### Same bytes in RAM and on the wire

The ring stores these records; the dump ships them **verbatim** — memory format **==** link
format. The only wire-only addition is a per-core **block header** prepended when one dump
carries several cores (so the host splits the stream by core); it wraps the records, never
rewrites them. A single-core dump on the wire is byte-identical to the ring.

#### Buffer depth vs ISO-TP

Classic ISO-TP caps one transfer at **4095 bytes** (12-bit FF length). An 8 KB ring
(2048 × 4 B) is bigger, so:

1. **Default the ring to ≤ 4095 B** (~1000 coarse / ~500 fine records) → a dump is one ISO-TP
   transfer. Deeper *flat* history rarely helps; the **trigger / flight-recorder** keeps the
   *relevant* window instead.
2. **ISO-TP 32-bit escape** — an FF with the 12-bit length = 0 carries a following 4-byte length
   (up to 4 GB in one transfer). Use it for larger blocks *if* our isotp stack **and** the host
   tool both support the escape (to verify).
3. **App-layer paging** — dump a page at a time (`records [offset, offset+N)`), one message each,
   until the host has all `records_used` from the rsp. Universal (works over plain CAN), chattier.

Default is #1; #3 is the mechanism when a config asks for a ring larger than one transfer.

#### Worked example

`task_1` runs, `isr_512` preempts it, it resumes then blocks; the core idles until the timer
`isr_128` fires and readies `task_2`. Manifest: `task_1`→thread 1, `task_2`→thread 2,
`isr_512`→isr_id 5, `isr_128`→isr_id 3.

| # | event | bytes | decode |
|---|---|---|---|
| 1 | task_1 scheduled | `00 01 64 00` | SWITCH → thread 1, Δ100 |
| 2 | isr_512 preempts | `20 05 2C 01` | ISR 5, Δ300 → task_1 ran 300 µs |
| 3 | isr_512 returns  | `40 00 14 00` | ISR_END, Δ20 → isr_512 ran 20 µs, task_1 resumes |
| 4 | task_1 blocks    | `61 00 90 01` | IDLE reason=block, Δ400 → task_1 ran 400 µs more |
| 5 | isr_128 fires    | `20 03 E8 03` | ISR 3, Δ1000 → idle lasted 1000 µs |
| 6 | isr_128 returns  | `40 00 18 00` | ISR_END, Δ24 → isr_128 ran 24 µs (readied task_2) |
| 7 | task_2 scheduled | `00 02 02 00` | SWITCH → thread 2, Δ2 |

**28 bytes** for the whole scenario. Accumulating deltas rebuilds the timeline:

```
[  100,  400)  task_1    300 µs
[  400,  420)  isr_512    20 µs   (preempts task_1)
[  420,  820)  task_1    400 µs   (resumed)
[  820, 1820)  idle     1000 µs   (task_1 blocked)
[ 1820, 1844)  isr_128    24 µs   (timer)
[ 1844, 1846)  (schedule gap)
[ 1846,    …)  task_2
```

### Fine — add fb.handler runs (8-byte records)

The detailed short-window level is the **same event stream** as coarse — same `type` in `b0`'s
top 3 bits, same decoder state machine — with **one extra type, HANDLER** (an fb.handler
invocation) and full precision. 8 bytes buys a `u16` handler_id, a `u16` **raw** interrupt vector
(no manifest mapping needed), and per-event `cpu_us`, with **absolute** `u24` timestamps instead
of deltas (16.7 s window; no TICK bridging):

```
b0 = (type << 5) | aux5
 type 0  SWITCH   aux5=reason  b1=to_thread(u8)          b3-5=start_us(u24)
 type 1  ISR      aux5=0       b1-2=irq(u16 raw vector)  b3-5=start_us(u24)  b6-7=cpu_us(u16)
 type 2  ISR_END  aux5=0                                 b3-5=start_us(u24)
 type 3  IDLE     aux5=reason                            b3-5=start_us(u24)
 type 5  HANDLER  aux5=flags   b1-2=handler_id(u16)      b3-5=start_us(u24)  b6-7=cpu_us(u16)
```

- **HANDLER** `flags` (aux5): `bit0 overran | bit1 preempted | bit2 first-run | bit3 saturated`.
  `cpu_us` is the measured run time — the response time on a no-IRQ bare-metal core; on an RTOS
  it excludes ISR time, which appears as the ISR events themselves.
- **ISR carries the raw `u16` vector** here (a >2000-vector MCU is fine); the fine level doesn't
  need coarse's `u8 isr_id`. Absolute starts + `cpu_us` give each event's duration directly
  (coarse infers it from the next record's delta).
- Same decoder as coarse — *current thread* + *ISR-nesting stack* — with HANDLER runs slotted
  inside the owning thread's interval.

**Interrupts are events, never threads.** At either level an interrupt is its own **ISR /
ISR_END** event (coarse `u8 isr_id`, fine `u16` vector) — *never* folded into the `thread_id`
space, which stays `u8` (threads are genuinely few; 2000+ vectors would never fit). An ISR
preempts the running context and returns to it; only if it wakes a higher-priority thread does a
SWITCH follow. Fields come from the `_tx_execution_isr_enter`/`_isr_exit` hooks (active vector
from Cortex-M `ICSR.VECTACTIVE`). At high interrupt rates ISR events may be routed to a **separate
buffer** so they don't evict thread/handler events — same layout either way.

#### Wire framing: the per-core block header (type 7)

Both levels store **only records** in RAM. A **multi-core** dump prepends one **block header**
per core on the wire (wire-only — never in the ring) so the host splits a single `record_id`
stream by core without correlating to the rsp. It's a `type 7` record, the same width as the
buffer:

```
coarse (4 B):  b0=(7<<5)  b1=core(u8)  b2-3=count(u16 LE)
fine   (8 B):  b0=(7<<5)  b1=core(u8)  b2-5=count(u32 LE)
```

A decoder that may receive multi-core dumps starts a new core block on `type 7`. A **single-core**
dump has **no** header — the TraceRsp already names the core, so the wire is byte-identical to the
ring (what the single-core `trace_demo` sends). One level per buffer, so coarse and fine records
never mix.

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
4. **P4 — ThreadX preemption + thread-switch capture** (`TX_ENABLE_EXECUTION_CHANGE_NOTIFY`;
   our `_tx_execution_thread_enter/exit` emit thread-switch records at `_tx_thread_schedule`,
   `reason` from the outgoing thread's state; ISR enter/exit for the ISR bucket).
   `REQ-TRACE-005/008`.
5. **P4b — multi-core dump-in-one-command** (`core_mask` fan-out; per-core self-describing
   ISO-TP blocks, gathered over IOC). `REQ-TRACE-009`.
6. **P5 — blobly_net**: load the manifest, decode records, render the timeline / jitter /
   preemption / swimlane views above.

> **Host vs target.** The record kinds, codecs, `core_mask` control, and multi-core dump
> fan-out are portable and verified on host/vcan (multi-core = several loom schedulers in
> one process, one bus loop). The **source** of thread-switch records is the ThreadX
> execution-change-notify hooks (`_tx_execution_thread_enter/exit` at `_tx_thread_schedule`),
> which have no equivalent on the cooperative host — so the host harness injects synthetic
> switch records to exercise the codec/dump end-to-end, as the DWT `hw` trigger is seam-only
> until silicon.

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
- **REQ-TRACE-008** — where the kernel is preemptive, the ECU shall capture thread context
  switches, each recording the thread now running, timestamp, and reason (the outgoing
  thread's fate), so a dump yields the context-switch timeline. *(ThreadX
  execution-change-notify hooks the source: `_tx_execution_thread_enter/exit`; no-op on a
  cooperative core)*
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
6. **Record width**: **decided** — **two** fixed widths, one per level, both **type-tagged**
   in `b0` (top-3-bit `type`): **coarse 4 B** (delta-encoded threads / ISRs / idle — the
   long-history who-had-the-core timeline) and **fine 8 B** (absolute-time, adds fb.handler
   runs + raw `u16` ISR vectors + `cpu_us`). One width per buffer, so the ring stays a single
   no-alloc fixed-stride array and there's one dump format per level.
7. **Multi-core dump framing**: **decided** — `core_mask` in TraceCmd fans out; per-core
   self-describing ISO-TP blocks (block-header record + records), in ascending core order,
   each pulled over IOC by the bus core.
