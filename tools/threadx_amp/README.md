# ThreadX AMP proof-of-concept

Proves **real multicore ThreadX on the Linux host**: one ThreadX kernel instance
per core, each in a forked process pinned to its CPU, all sharing blobly's
lock-free IOC in `MAP_SHARED` memory. This is the `fork + shared-memory` AMP
method — not the stock single-core `linux/gnu` port.

ThreadX is **not vendored** here (external dependency). To reproduce:

```sh
# 1. get ThreadX and build the 64-bit Linux library
git clone --depth 1 https://github.com/eclipse-threadx/threadx
( cd threadx/ports/linux/gnu/example_build && make tx.a ARCH64=1 )

# 2. build the AMP harness against it + blobly's IOC shim
TX=$PWD/threadx
gcc -g -std=c99 -D_GNU_SOURCE -DTX_LINUX_MULTI_CORE -DTX_ENABLE_EVENT_TRACE \
    -DTX_LINUX_DEBUG_ENABLE \
    -I "$TX/common/inc" -I "$TX/ports/linux/gnu/inc" -I ../../osal \
    tx_amp.c ../../osal/osal_native.c \
    "$TX/ports/linux/gnu/example_build/tx.a" -lpthread -lrt -o tx_amp

# 3. run
./tx_amp
```

Expected:

```
ThreadX AMP on Linux: 2 ThreadX kernels, 1 per forked core, shared IOC
  core0 writer thread: ~6.7M ops
  core1 reader thread: ~5.1M ops  torn=0
  wall-clock: ~1000 ms  (two concurrent 1s workloads => true parallelism)
```

## Why it works (see docs/threadx-amp.md)

The port's `TX_LINUX_MULTI_CORE` confines each ThreadX process to a single core —
i.e. one kernel = one core. fork()ing one instance per core gives each its own
private kernel state (the global `_tx_linux_mutex` becomes per-core, no longer a
global serializer), while sharing only the `mmap` IOC region. Result: genuine
parallel AMP, the same shape as the target (per-core OS instance + shared SRAM).
