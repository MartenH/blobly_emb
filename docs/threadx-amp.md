# ThreadX AMP on Linux (real multicore)

The stock ThreadX `ports/linux/gnu` port is a **single-core** functional
emulation: a process-global `_tx_linux_mutex` serializes all threads, so only one
runs at a time. That's fine for API validation but useless for the multicore
performance work blobly_emb is built around.

**We get real multicore anyway** — by running ThreadX in an **AMP** topology, the
same method a multicore AUTOSAR-OS-on-Linux uses (and that blobly's own sim
already assumes): one independent OS instance per core, sharing only explicit
global RAM.

## The method

1. **`mmap(MAP_SHARED)` the IOC region before forking** — the host equivalent of
   shared SRAM. (blobly: `osal.ioc_shared_init()` / `blob_ioc_shared_init`.)
2. **`fork()` one process per core, pin each to its CPU** — each is a full,
   independent ThreadX kernel running its own threads on its own core, truly in
   parallel. (blobly: `osal.start_core` / `blob_start_core`.)
3. The port's `TX_LINUX_MULTI_CORE` already confines each ThreadX process to one
   core — i.e. **one kernel = one core**, which is exactly the AMP unit.

The crucial point: `fork()` gives each core its own private copy of all ThreadX
kernel state for free, so the global `_tx_linux_mutex` becomes **per-core** and
stops being a global serializer. Cores run in parallel; they touch each other
only through the shared IOC. (This is why AMP uses processes, not threads: N
ThreadX instances as threads in one process would collide on the kernel's global
statics; `fork` sidesteps that entirely.)

## Proven

`tools/threadx_amp/` builds two ThreadX kernels (writer on core 0, reader on
core 1) exchanging a 64-byte non-scalar record through blobly's triple-buffer IOC:

```
core0 writer thread: ~6.7M ops
core1 reader thread: ~5.1M ops  torn=0
wall-clock: ~1000 ms   (two concurrent 1s workloads => true parallelism)
```

`torn=0` proves the lock-free IOC is correct across two ThreadX kernels; the
~1000 ms wall-clock (not ~2000) proves they ran in parallel. Throughput matches
the non-ThreadX cross-process bench (`tools/ioc_bench_mp`), so the ThreadX threads
are doing real work through the same IOC.

`tools/threadx_amp/tx_demo.c` goes further: it runs the **actual SpeedMonitor
demo** (the `app/speed_monitor.v` decision) on ThreadX AMP — IO partition on
core 0 sweeping `VehicleSpeed`, App partition on core 1 deciding the lamp, signals
crossing via the real IOC, Loom dispatch realized as a ThreadX thread +
`tx_thread_sleep`. The lamp turns on at 130 km/h (first value > 120), proving the
application behavior — not just raw IOC throughput — runs on ThreadX.

## What this is and isn't

- **Is:** real parallel multicore ThreadX on the host — AMP (N independent
  kernels), matching the target topology (per-core OS + shared SRAM) and blobly's
  partition model. Lets us run the actual ThreadX kernel/API under true
  parallelism, with no hardware.
- **Isn't:** ThreadX **SMP** (one kernel migrating threads across a shared ready
  queue). That needs ThreadX-SMP on real multicore silicon. For an automotive AMP
  stack, per-core instances is the correct model, not a compromise.

## The real app on the ThreadX backend (done)

The OSAL now has a **build-selectable ThreadX backend** — and the actual V app
(`loom.Scheduler` + `app.SpeedMonitor`, unchanged) runs on it.

- `osal/osal_threadx.c` (`#ifdef BLOBLY_THREADX`): `blob_tx_start_core` forks a
  process per core and enters `tx_kernel_enter`; `tx_application_define` runs the
  partition's V entry as a ThreadX thread; `blob_tx_sleep_us` yields via
  `tx_thread_sleep`. IOC + shared memory + `waitpid` are reused from
  `osal_native.c`.
- `osal/osal.v`: `start_core` and `sleep_us` pick the backend with
  `$if threadx ? { ...ThreadX... } $else { ...POSIX... }`. `app/`, `comm/`,
  `loom/` are untouched.
- `cmd/threadx_demo/demo.v`: the real Loom + SpeedMonitor across two AMP
  partitions. **Same V source, two backends:**

```sh
make demo                                  # POSIX backend (fork per core)
make demo-threadx THREADX=/path/to/threadx # ThreadX backend (-d threadx, links tx.a)
```

Both print `lamp first ON at kph=130` — the application behaves identically
whether scheduled by the host sim or by per-core ThreadX kernels. ThreadX stays
external (not vendored); point `THREADX` at a checkout with `tx.a` built (see
`tools/threadx_amp/README.md`).

The remaining step toward a target build is swapping the SocketCAN driver port
for an MCU MCAL and building for real silicon; the OS seam is now in place.
