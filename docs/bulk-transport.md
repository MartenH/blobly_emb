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

DDS is the default middleware, but ROS 2 explicitly **bypasses it for bulk on one
machine**, because publishing a camera frame through a loopback DDS stack copies it
several times:

| path | mechanism |
|---|---|
| same process | **intra-process comms** — the message pointer is passed; zero copy |
| same machine | **shared-memory transport** (FastDDS SHM / data-sharing), or **iceoryx** via `rmw_iceoryx` |
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
- a **mailbox/doorbell interrupt** to notify — on ST parts that is **IPCC**, with **HSEM**
  available for locking;
- named **channels/endpoints** above it, so several logical streams share one transport.

Linux+M4 (STM32MP1), Zephyr+M4, TI, and NXP all ship this. **The H755 has IPCC and HSEM,
and `duo.h` uses neither** — it polls. That is fine for one 2 KB trace snapshot per dump;
it is not fine for a continuous bulk stream, because polling either burns cycles or adds
latency.

Neighbours in the same space: TI **MessageQ**, NXP **MU + eRPC**, and ST's own OpenAMP
middleware.

## Automotive framing

- **AUTOSAR Classic**: `LdCom` — pass the PDU **transparently**, no signal packing, and
  let PduR + a TP segment it. Named in
  [autosar-comparison.md](autosar-comparison.md) as the gap we have.
- **AUTOSAR Adaptive**: `ara::com` with the zero-copy binding — which *is* iceoryx.
- **SOME/IP-TP**: segmentation for payloads past one datagram.

## What this implies for blobly

The convergence is strong enough to just follow it. A generated bulk endpoint would be:

1. **A pool of N fixed-size buffers** in the shared window, N and size fixed at build time
   from `ecu.toml` — no-alloc holds by construction, and the RAM cost is visible in config.
2. **An SPSC descriptor ring** transferring ownership. It must use the **same plain-store
   discipline as `xioc`**, not `LDREX`/`STREX`: the H755 cores do not arbitrate exclusives
   (162 torn reads in 200k, measured 2026-07-12), which is the constraint that shaped the
   whole cross-core design.
3. **A doorbell** — IPCC interrupt where the hardware has one, falling back to the current
   poll. This is the piece `duo.h` is missing entirely.
4. **A loan/publish API** on the producer and peek/release on the consumer, so an FB never
   holds a buffer it allocated.
5. **The same declaration for off-chip.** A bulk endpoint whose peer is another *node*
   should mean ISO-TP (CAN) or SOME/IP-TP (eth) — the transport derived from where the
   endpoint sits, exactly as signals already work.

Two decisions to make deliberately, not by default:

- **Whether the ring is generic or trace-shaped.** The trace dump wants freeze-then-stream;
  a sensor stream wants continuous latest-N. One ring can serve both, but the API should
  admit both from the start.
- **Whether bulk stays module-only.** Today only a ComModule may own a link. Letting an FB
  declare a bulk endpoint is the ergonomic win, but the isolation rule (FBs never import a
  driver, CI-enforced) means the *socket/link stays in the platform* — the FB gets a
  loaned buffer, never a handle.

## Sources worth reading before building

- Eclipse **iceoryx** — chunk pools, loaned messages, the `ara::com` zero-copy binding.
- **OpenAMP** / RPMsg / VirtIO vring layout; ST's IPCC + HSEM reference manual sections.
- Linux **dma-buf** and **io_uring** — for the descriptor-ring and handle-passing patterns.
- AUTOSAR **LdCom** SWS — the transparent-PDU contract.
