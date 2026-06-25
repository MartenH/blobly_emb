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
- **`load_bench`** — a whole-system load test: 4 cores (fork-per-core, shared IOC),
  **8 CAN buses on core0**, **50 FBs per core**, each FB reading 10 + writing 10
  signals (CAN-bridged + cross-core internal) every 10 ms. Reports per-core CPU load:

  ```
  core  role              load    work/cycle
   0    8 buses + 50 FBs  2.14%   216 us     <- carries the 8 bridges' codec + IOC
   1    50 FBs            1.51%   153 us
   2    50 FBs            1.39%   141 us
   3    50 FBs            1.53%   155 us
  ```

  **Takeaway:** a busy ECU (8 buses, 200 FBs, ~4k signal ops/cycle) sits at **~2%**
  per core at the 10 ms rate — the IO core (core0) ~40 % heavier from CAN codec, and
  ~50× headroom before saturation. The constants at the top of the bench are tunable
  to model other configurations (more buses, faster cycles, heavier FBs).

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

## Why the triple buffer is wait-free for non-scalars

Three buffers; the indices `{writer, published, reader}` are always a permutation
of `{0,1,2}`, rotated by a single atomic exchange. The writer fills its private
buffer and swaps it in; the reader swaps the published buffer out for its own.
Neither side ever touches the buffer the other is using, so there is no shared
payload to race on and no reason to retry — for a payload of any size or shape.
See `blob_ioc_pub` / `blob_ioc_acq` in [`osal/osal_native.c`](../osal/osal_native.c).
