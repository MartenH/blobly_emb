# Bulk transport — how everyone else solves it, and what that implies here

> Design note (2026-07-23). Prompted by a plain question: a cross-core signal is capped at
> one xioc cell (8 B), so how do you move an *object*? Before designing an endpoint, this
> page surveys what other systems converged on. Nothing here is built.
> Companion: [um/move-data.md](um/move-data.md) (what exists today and its limits).

## The short answer

Every serious system converges on the **same shape**:

> a **pre-allocated pool of fixed-size buffers** in memory both sides can reach, a
> **descriptor ring** that transfers *ownership* of a buffer, and a **doorbell** to wake
> the far side.

The payload is never copied through a channel — a *reference* moves. The differences
between DDS, RPMsg, iceoryx and dma-buf are mostly about who owns the pool and what the
doorbell is, not about the shape.

blobly's existing cross-core trace handoff (`boards/h755zi/duo.h`) is already a degenerate
instance of this: one buffer, a `{req_seq, op, ack_seq, count}` descriptor, and a polled
doorbell. The generalisation is "more than one buffer, and an interrupt instead of a poll".

## ROS 2 — no, it is not only DDS

DDS is the default middleware, but ROS 2 avoids paying the **full serialize-and-loopback
cost for bulk on one machine** — publishing a camera frame through the wire path copies
it several times. The mechanisms differ in *what* they replace:

| path | mechanism |
|---|---|
| same process | **intra-process comms** — the message pointer is passed (conditional on the pub/sub topology and ownership); zero copy, above the middleware |
| same machine | **FastDDS SHM / data-sharing** — still DDS, delivering *through* shared memory instead of the wire (kills serialization/wire copies, does not bypass the middleware); or **iceoryx** via `rmw_iceoryx`, which genuinely *replaces* DDS |
| across machines | DDS on the wire (RTPS) |

The interesting one for us is **iceoryx**, because its constraints are ours:

- a **fixed chunk pool** carved at startup — **no dynamic allocation at runtime**;
- **lock-free** queues between publisher and subscriber;
- a **loan → fill → publish** API: the publisher *borrows* a chunk from the pool, writes
  into it in place, and publishes a reference. It never allocates and never copies.

That "loan" ergonomic is the part worth stealing. In a no-alloc system the producer must
not own the buffer — the *transport* must hand it one. It is also not a toy: iceoryx is
the reference zero-copy binding for **AUTOSAR Adaptive `ara::com`**.

## Linux — pass a handle, not the bytes

The recurring Linux answer is the same idea with kernel-managed handles:

- **shared memory** (`mmap`/`memfd`) plus a futex/eventfd doorbell — the classic;
- **dma-buf / memfd**: a buffer that *has a file descriptor*. You pass the **fd** over a
  unix socket (`SCM_RIGHTS`) and the receiver maps it — the data never travels through the
  socket. This is how graphics/video pipelines move frames between processes;
- **io_uring**: shared submission/completion **rings** between user space and the kernel —
  descriptors again, doorbell instead of syscall-per-op;
- **splice/vmsplice**: move *pages* between pipes without copying them.

The lesson is not any one API, it is the discipline: **the control channel carries a
reference; the data channel is memory both sides already mapped.**

## Heterogeneous cores on one chip — this is the closest analog

Our actual problem (CM7 ↔ CM4, shared SRAM, no coherency) has a de-facto industry
standard we do not currently use or mention anywhere: **OpenAMP / RPMsg over VirtIO
vrings**.

- two **vrings** (one per direction) of descriptors in shared memory;
- fixed buffers carved from that region at init;
- a **mailbox/doorbell interrupt** to notify — on ST parts that is **IPCC** where it
  exists (STM32MP1, WB/WL), with **HSEM** available for locking;
- named **channels/endpoints** above it, so several logical streams share one transport.

Linux+M4 (STM32MP1), Zephyr+M4, TI, and NXP all ship this. **The H755 has no IPCC** — its
inter-core notification is **HSEM's semaphore-release interrupt** (each core can take an
interrupt when the other releases a semaphore; ST's own H7 OpenAMP port builds the RPMsg
doorbell exactly this way). **`duo.h` uses none of it** — it polls. That is fine for one
2 KB trace snapshot per dump; it is not fine for a continuous bulk stream, because polling
either burns cycles or adds latency.

Neighbours in the same space: TI **MessageQ**, NXP **MU + eRPC**, and ST's own OpenAMP
middleware.

## Automotive framing

- **AUTOSAR Classic**: `LdCom` — pass the PDU **transparently**, no signal packing, and
  let PduR + a TP segment it. Named in
  [autosar-comparison.md](autosar-comparison.md) as the gap we have.
- **AUTOSAR Adaptive**: `ara::com` with the zero-copy binding — which *is* iceoryx.
- **SOME/IP-TP**: segmentation for payloads past one datagram.

## Does any of this need an MMU? (No — and an MPU part has it easier)

Worth answering directly, because it decides how much of the above is even portable.

**`io_uring` does not transfer at all** — it is a *Linux syscall interface*. The rings live
in kernel memory and are `mmap`'d into user space; there is no library to port to a
Cortex-M. What transfers is the **pattern** (a shared submission/completion ring instead
of a call per operation), and the pattern needs no MMU whatsoever — it is a ring in memory
both sides can see.

**iceoryx's implementation needs an MMU; its design does not.** iceoryx maps one physical
shared-memory segment into several *processes*, and those mappings land at **different
virtual addresses** in each — which is exactly why iceoryx cannot store raw pointers in
shared memory and uses **relative (offset) pointers** instead. `shm_open`, `mmap`, fd
passing, offset pointers: that machinery exists to reconstruct a **single shared address
space**.

An MCU already has one. SRAM4 is at `0x38000000` for both H755 cores. So the MMU-era
apparatus simply drops out:

| MMU system needs | on an MPU part |
|---|---|
| `mmap` the segment per process | nothing — the window is already addressable |
| relative/offset pointers | plain pointers; the same address means the same byte on both cores |
| fd/handle passing to share a buffer | pass the offset (or nothing — the ring entry *is* the reference) |
| page-level permissions | MPU regions, statically configured |

**What you lose** without an MMU is real but mostly irrelevant here: no per-process virtual
address spaces (so a wild pointer reaches anything the MPU permits — which is why the
generated region table in [memory-protection.md](memory-protection.md) matters), and no
demand paging or growable pools (irrelevant: no-alloc means the pool is fixed at build
time by design).

**The MPU's important job here is cacheability, not protection.** The hazard on these
parts is not one core reading another's memory — it is one core's **D-cache** holding a
stale line. `xioc.h` already states the rule: shared buffers must live in uncached memory,
"the D-cache-off policy, **or an MPU non-cacheable region**". Today the H755 runs with
D-caches off, so the question is moot — but a bulk pool is precisely the feature that
would make you want D-cache *on* for the rest of the map, and at that moment the MPU
region attribute becomes the mechanism that keeps the pool correct. Note the asymmetry:
the CM7 has a D-cache, the CM4 (Cortex-M4) has none, so only the CM7 side needs the
attribute.

So: **MPU is enough, and the constraint that actually bites is cache coherency, not memory
protection.**

## The portable contract — this is not an STM32 design

The H755 is the first instantiation, not the shape (the same directive the multi-image
emitter was built under). Strip the survey to what the mechanism actually *requires* and
it is three primitives, none of them ST-specific:

1. **A shared window both endpoints address identically** — no translation between them.
2. **Single-copy-atomic aligned 32-bit stores** across that window.
3. **An ordering barrier** (`DMB`, a fence, or the compiler/OS equivalent).

Everything else — doorbell, cache rules, protection — is a **per-board seam**, and the
repo already has the seam: the porting table realises the IOC region as `mmap(MAP_SHARED)`
on host, shared SRAM on STM32, a shared section on an AUTOSAR ECU. The bulk pool rides
the *same* seam; a port that has the IOC region has the bulk window for free.

So the layering is:

| layer | contents | varies per board? |
|---|---|---|
| **portable core** (`boards/common/`, like `xioc.h`) | pool + SPSC descriptor ring + loan/fill/publish and peek/release, plain 32-bit stores + barriers | no |
| **board ops** (tiny, optional) | `bulk_notify()` doorbell; `bulk_flush()/bulk_invalidate()` cache hooks | yes |
| **config/codegen** | the endpoint in `ecu.toml`: name, buffer size × count, endpoints; the generator places the pool in the board window and derives the transport | no |

Three rules keep it universal rather than accidentally ST-shaped:

- **Plain stores, never exclusives.** The xioc lesson generalises: `LDREX`/`STREX` (and
  their equivalents) are not guaranteed to arbitrate between *sides* — cores, a core and a
  DMA engine, a core and an accelerator. Aligned-word stores + barriers are the lowest
  common denominator that is correct everywhere the three primitives hold.
- **The doorbell is an optimization, never a correctness requirement.** Define it as an
  edge that may be lost or coalesced, carrying no data — the ring state is the only truth.
  Then IPCC (ST), MU (NXP), IPC (TI), an SGI on A-class, an `eventfd` on the host, or
  *nothing at all* (poll) are interchangeable, and the RPMsg/virtio discipline is kept.
- **Cache maintenance is a pair of hooks that default to no-ops.** On a part where the
  window is uncached (MPU attribute, or caches off), they compile away. On a part where it
  isn't, the port supplies clean/invalidate. The contract is "the reader sees what the
  writer published after the barrier", not "there is no cache".

A side effect worth wanting: because the host realization is `mmap(MAP_SHARED)` + fork
(already proven by `ioc_bench_mp`), the same ring is **testable on the host, cross-process,
in CI** — bulk transport gets the sim-first treatment everything else here gets, before it
ever touches a board.

## What this implies for blobly

The convergence is strong enough to just follow it. A generated bulk endpoint would be:

1. **A pool of N fixed-size buffers** in the shared window, N and size fixed at build time
   from `ecu.toml` — no-alloc holds by construction, and the RAM cost is visible in config.
2. **An SPSC descriptor ring** transferring ownership. It must use the **same plain-store
   discipline as `xioc`**, not `LDREX`/`STREX`: the H755 cores do not arbitrate exclusives
   (162 torn reads in 200k, measured 2026-07-12), which is the constraint that shaped the
   whole cross-core design.
3. **A doorbell** — a mailbox interrupt where the hardware has one (HSEM release-interrupt
   on the H755; IPCC on parts that have it), falling back to the current poll. This is the
   piece `duo.h` is missing entirely.
4. **A loan/publish API** on the producer and peek/release on the consumer, so an FB never
   holds a buffer it allocated. **`loan()` is fallible by contract**: when a slow consumer
   holds all N buffers, it returns an exhaustion value — it never blocks, never faults,
   and never reuses a buffer someone still owns. Without that clause "no-alloc by
   construction" is a claim with no leg to stand on, because exhaustion *will* happen and
   the only other behaviours are the three wrong ones.
5. **The same declaration for off-chip.** A bulk endpoint whose peer is another *node*
   should mean ISO-TP (CAN) or SOME/IP-TP (eth) — the transport derived from where the
   endpoint sits, exactly as signals already work.

## Who runs it — FBs for signals, service threads for everything else

The execution-model question ("but who *calls* this API?") has an answer the tree already
practices, three times, hand-written:

- **An FB handler is the wrong home for bulk by construction.** It is cyclic, must finish
  inside its period, and may never block — the right contract for signal work, fatal for a
  socket or a stream.
- **A plain ThreadX thread is the right home**, and on the eth side it is already genuinely
  *nice*: NetX is ThreadX-native, so `nx_tcp_socket_receive(&sock, &p, timeout_ticks)`
  blocks the thread properly, with a timeout, no polling. The existing instances:
  - the **comm thread** — blocks on the CAN Rx, owns the bus, runs the modules;
  - the **DoIP service thread** (`examples/h735_doip`) — `netx_glue.c` owns
    ThreadX/NetX/sockets and exposes a four-call seam (`net_stream_recv/send`, timeout in
    ticks); a dedicated thread runs the V protocol loop against that seam, and every byte
    above the stream is unit-tested V (`comm.doip` + `comm.uds`);
  - `examples/h735_net`'s echo/telemetry threads.

So the model is **two kinds of application execution**, not one:

| | **FB handler** | **service thread** |
|---|---|---|
| paced by | the clock (its period) | the *data* (blocking recv / doorbell, with timeout) |
| may block | never | yes — that is its job |
| carries | signals, ≤64 B, latest-value | streams, bulk rings, request/response |
| touches a driver | never (lint-enforced) | never *directly* — it gets an injected **seam** (`net_stream_recv`-shaped), the platform owns the socket/window |
| testable | pure V vs ports | pure V vs the seam — the DoIP loop already tests this way |

What is missing is only that the second kind is **not declarable**: each instance is
bespoke glue. The generalisation writes itself — a `[[partition.thread]]` with an
**endpoint binding** (a stream, a datagram socket, or a bulk ring), where loom2v generates
the glue that today is hand-written per example: the platform opens the socket / places
the ring, creates the thread, and hands the loop its seam. The isolation rule survives
untouched, because the seam *is* the boundary — same as `main.v` is today.

The cross-core bulk consumer is then just another service thread: it blocks on a ThreadX
event flag that the doorbell ISR (HSEM release-interrupt on the H755) sets — the same
"sleep until data or timeout" shape as the socket case, which is exactly why the two
belong to one endpoint concept.

One isolation consequence to face rather than wave at: a consumer that receives a loaned
buffer **by reference** has the shared pool mapped into its own partition — that is
cross-core shared state reached outside `osal.ioc_*`, which the architecture forbids as
an ad-hoc arrangement. So the loan/peek path is only admissible as a **sanctioned
transport**: the pool becomes an entry in the generated MPU region table with
*directional* permissions (producer-writable, consumer-readable, ownership switched by
the ring), exactly as the IOC regions are sanctioned today — or bulk termination stays in
a platform module and the app never touches the pool. "The FB doesn't open the socket" is
necessary, not sufficient.

One decision left to make deliberately, not by default:

- **Whether the ring is generic or trace-shaped.** The trace dump wants freeze-then-stream;
  a sensor stream wants continuous latest-N. One ring can serve both, but the API should
  admit both from the start.

(The earlier open question — "does bulk stay module-only?" — dissolves under this model: a
ComModule is just a platform-owned service loop on the comm thread, and an *application*
bulk consumer is a declared service thread. Same species, different owner.)

## Sources worth reading before building

- Eclipse **iceoryx** — chunk pools, loaned messages, the `ara::com` zero-copy binding.
- **OpenAMP** / RPMsg / VirtIO vring layout; ST's HSEM (H7 dual-core) and IPCC (MP1/WB)
  reference manual sections.
- Linux **dma-buf** and **io_uring** — for the descriptor-ring and handle-passing patterns.
- AUTOSAR **LdCom** SWS — the transparent-PDU contract.
