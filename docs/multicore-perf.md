# Multicore performance: lock-free signal exchange

Goal: cross-core signal read/write must be **VERY** fast and must **never degrade
to spinning on a lock**, including for **non-scalar** (multi-field) signals.

## Design principles

1. **Share almost nothing.** Each partition has its own Loom scheduler and its own
   driver channel. Intra-partition signals are plain local memory — zero
   synchronization. Only signals that genuinely cross cores touch the IOC.
2. **No locks, anywhere, in steady state.** The IOC is lock-free. There is no
   mutex in any runtime path.
3. **No false sharing.** Every IOC slot is cache-line aligned and padded to whole
   cache lines, so a writer on one channel never invalidates another channel's
   line. This is the difference between "lock-free" and "actually fast."
4. **Single-writer per channel (SPSC).** Each IOC channel has exactly one `from`
   partition (enforced by config). This invariant is what makes the lock-free
   algorithms valid.

## IOC is a per-channel transport, not one fixed scheme

The IOC API (`publish`/`acquire`) is uniform; each channel picks a **transport**
by its timing needs, payload size, and memory budget. App/comm code never
changes. Software shared-memory backends today:

| transport | writer | reader | non-scalar snapshot | memory | failure mode |
|-----------|--------|--------|--------------------|--------|--------------|
| `seqlock` (1×) | wait-free | may retry | yes | 1× | reader starves if writer saturates |
| `double` (2×) | wait-free | wait-free | yes *if reader keeps up* | 2× | torn if writer laps reader |
| `triple` (3×) | wait-free | wait-free | always | 3× | none (bounded, constant) |

## How each transport is implemented

All three live in [`osal/osal_native.c`](../osal/osal_native.c) and share one shape:
a **cache-line-aligned, cache-line-padded** slot holding the payload (`[64]u8` +
length) plus a small atomic index/counter. All three assume **one writer per
channel** (SPSC) — that invariant is what makes them correct without locks. The
payload copy is a `volatile` byte loop (`vcopy`) so the compiler can't hoist or
reorder the data access across the atomic that guards it.

### seqlock (1×) — one buffer + a version counter

One buffer guarded by a sequence counter: **even = stable, odd = write in
progress, 0 = never written.**

```c
// writer (blob_ioc_write)
seq++  (-> odd, "in progress");  release-fence
write len; write data
store seq+1 (RELEASE)            // -> even, "published"

// reader (blob_ioc_read), retry loop
seq0 = load(ACQUIRE)
if seq0 == 0:   return empty     // never written
if seq0 is odd: retry            // writer mid-update
copy len, data;  acquire-fence
seq1 = load(ACQUIRE)
if seq0 == seq1: done            // counter unchanged across the copy -> consistent
else:            retry           // a write landed mid-copy -> torn, try again
```

The reader never blocks the writer but **may retry** if a write lands during its
copy — under a saturating writer that retry loop is the 4.6 µs worst case above.
Cheapest memory (1×) and the only valid scheme for **single-writer / many-readers**
fan-out (the `load_bench` fan-out reads use it).

### double buffer (2×) — two buffers + an active index

Two buffers, one atomic `active` index. The writer always fills the *inactive*
buffer, then flips:

```c
// writer (blob_ioc_pub2)
w = active ^ 1                   // the buffer the reader isn't on
write buf[w]
store active = w (RELEASE)       // publish the flip

// reader (blob_ioc_acq2)
a = load active (ACQUIRE);  copy buf[a]
```

Both sides are **wait-free** — a load and a store, no retry, no exchange. The
catch: if the writer **laps** the reader (flips twice during one copy), `buf[a]`
is being overwritten → a torn read (the `torn=612686` under saturation). Tear-free
whenever the reader keeps up — i.e. interval signals, the common case.

### triple buffer (3×) — three buffers, ownership rotated by one exchange

Three buffers and three indices — `{wb writer-back, shared published|DIRTY,
rf reader-front}` — that are **always a permutation of {0,1,2}**. Each side owns a
private buffer the other never touches; a single atomic exchange rotates ownership.
The low 2 bits of `shared` are the index; bit 2 is a **DIRTY** flag ("published
since the reader last took it").

```c
// writer (blob_ioc_pub)
write buf[wb]                              // fill our private back-buffer
old = exchange(shared, wb | DIRTY) (ACQ_REL)
wb  = old & IDX                            // old published buffer becomes our back-buffer

// reader (blob_ioc_acq)
cur = load shared (ACQUIRE)
if cur & DIRTY:                            // new data since last time
    old = exchange(shared, rf) (ACQ_REL)   // swap our front in, take the published one
    rf  = old & IDX
copy buf[rf]                               // always a private buffer -> never torn
```

Writer and reader each keep their own buffer and only ever swap the *third* one
through `shared`, so neither waits and there is no shared payload to tear on —
**wait-free for a payload of any size or shape.** The DIRTY bit lets a reader
polling faster than the writer skip the exchange and just re-read its current
front, so a fast poller costs a single atomic load. Costs 3× memory; reserve it
for the few channels with a saturating writer that still need wait-free, tear-free
reads. Indices start at the permutation `{wb=0, shared=1, rf=2}` (`init_db_indices`).

The `ACQ_REL` on each exchange is the publish/observe barrier: **release** so the
payload write is visible before the index that publishes it, **acquire** so the
peer sees the payload of the buffer it just took.

## Measured (host, 2 pinned cores, 64-byte non-scalar record, 1 s/side)

```
 saturated writer (worst case):
  seqlock 1x  :   216200 reads  (4625.35 ns/op)  torn=0        <- reader spins on retries
  double 2x   :  6404140 reads  ( 156.15 ns/op)  torn=612686   <- laps reader -> tears
  triple 3x   :  6701371 reads  ( 149.22 ns/op)  torn=0        <- wait-free, always safe
 paced writer @100us (realistic "signals at intervals"):
  seqlock 1x  : 30073529 reads  (  33.25 ns/op)  torn=0
  double 2x   : 28127863 reads  (  35.55 ns/op)  torn=0
  triple 3x   : 29659307 reads  (  33.72 ns/op)  torn=0        <- all three identical & safe
```

**Takeaway: for interval signals, 1× and 2× are tear-free and just as fast as
3×.** Don't triple SRAM by default — reserve `triple` for the few channels with
a saturating writer that also need wait-free reads.

## Running the benchmarks

`make bench` runs all three:

- **`ioc_bench`** — IOC transport cross-**thread** (2 pinned cores): the table above.
- **`ioc_bench_mp`** — IOC transport cross-**process** (fork-per-core + `MAP_SHARED`):
  the AMP model a per-core ThreadX instance sits on (see `threadx-amp.md`). Proves
  the lock-free IOC works across processes, not just threads (~200 ns/op, tear-free).
- **`loom_bench`** — the **Loom scheduler**'s dispatch tax: a static-table scan +
  indirect call, ~**0.7–0.95 ns per handler dispatch** (32-handler tick ≈ 22 ns).
  Negligible next to the IOC transfer — scheduling is not the cost, the data hop is.
- **`load_bench`** — a whole-system load *micro-model*: 4 cores (fork-per-core,
  shared IOC), **8 CAN buses on core0**, **50 FBs per core**, each FB reading 10 +
  writing 10 signals (CAN-bridged + cross-core internal) every 10 ms. Fan-out reads
  use the **seqlock** transport (single-writer / multi-reader — the valid transport
  when many FBs read one signal). Reports per-core CPU load:

  ```
  core  role              load    work/cycle
   0    8 buses + 50 FBs  1.89%   192 us     <- carries the 8 bridges' codec + IOC
   1    50 FBs            1.32%   134 us
   2    50 FBs            1.22%   124 us
   3    50 FBs            1.23%   125 us
  ```

  **Takeaway:** a busy ECU (8 buses, 200 FBs, ~4k signal ops/cycle) sits at **~2%**
  per core at the 10 ms rate — the IO core (core0) ~40 % heavier from CAN codec, and
  ~50× headroom before saturation. This is a hand-written model of the *work*; for
  the same load through the real generated stack on real vcans, see below. The
  constants at the top of the bench are tunable.

## Real-stack scale benchmark (`examples/scale` + `make bench-scale`)

The same shape, but through the **actual generated stack** on real SocketCAN: a
4-core / 8-bus / **200-FB** example whose config *and* FB handlers are generated
(`tools/scale_gen`), built by the normal generators, run on `vcan0..7` with
`cangen` traffic. Each partition is a core-pinned thread (core0 also hosts the 8
bus-bridge threads); CPU is sampled per-thread from `/proc` and summed by core:

```
core  role              load
 0    8 buses + 50 FBs  ~3.8%   <- 8 real bridge threads (recv + codec) + 50 FBs
 1    50 FBs            ~1.5%
 2    50 FBs            ~1.4%
 3    50 FBs            ~1.5%
RAM:  ~2.1 MB VmRSS  (~0.7 MB Pss), 13 threads
```

The IO core is ~2.5× the app cores here (vs ~1.4× in the micro-model) because core0
runs **eight real bridge threads** polling SocketCAN, not inline codec.

**Footprint** (built `-gc none` — the runtime doesn't allocate, so no collector):
448 KB binary (`.text` 378 KB, `.bss` 149 KB — most of it the IOC channel pool),
~2.1 MB RSS / **~0.7 MB Pss** for 200 FBs across 8 buses. (The default Boehm GC
would add ~180 KB code, ~255 KB `.bss`, ~1.6 MB Pss, and ~15 marker threads — none
of which a no-alloc runtime needs.) `make cfile` keeps the generated C the compiler
used (`bin/app.c`, ~32k lines / 1.4 MB) for inspection.

## Hardware transports (target backends, same API)

Real automotive MCUs provide dedicated IPC hardware that maps onto the same
per-channel transport slot — so you get isolation/throughput **without** the
software memory cost:

| HW mechanism | maps to | why / when |
|--------------|---------|------------|
| **HW semaphore** (NXP SEMA42, ST HSEM, AURIX) | guards a **1× single buffer** | hardware-arbitrated mutual exclusion, a few cycles, bounded — no software spin, no 2×/3× SRAM. Best for memory-tight channels with low contention. |
| **Inter-core DMA** | fills the inactive **2× double** buffer, then flips | the DMA engine moves the payload; cores spend ~0 cycles copying. Wins for **large** records and frees CPU. |
| **HW mailbox / messaging unit** (NXP MU, ST IPCC, TI IPC) | small fixed message + **doorbell IRQ** | best for **events/commands** and as the *notify* half: replace a polling `acquire` with an interrupt when new data lands. |

These are selected per channel in `config/ecu.toml` (`[[ioc]] transport = ...`)
and resolved by the OSAL's target backend; the seqlock/double/triple shared-
memory backends above are the host/sim defaults and the fallback on parts
without the peripheral.

## Cache coherency & placement (target reality)

Many multicore automotive parts are **not** fully cache-coherent across cores.
IOC shared memory must therefore live in a non-cached shared SRAM region (or be
explicitly cache-maintained). HW mailbox/DMA transports sidestep this because the
peripheral, not a shared cache line, carries the data. The OSAL backend owns this
placement; app/comm code is unaffected.

## Notes

The seqlock/double/triple algorithms above are the **host/sim** backends and the
fallback on parts without IPC hardware; the per-channel transport choice is config
(`[[ioc]] transport = …` in `config/ecu.toml`) and is resolved by the OSAL backend,
so app/comm code never sees which scheme a channel uses. On a non-cache-coherent
target the shared slots must live in non-cached shared SRAM (see *Cache coherency*
above); the math (permutation of buffers, single atomic index) is unchanged.
