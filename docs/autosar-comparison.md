# Communication patterns — blobly vs the AUTOSAR RTE/COM

blobly's **Loom** plays the role AUTOSAR gives the RTE (wiring + dispatch), and the
COM bridge plays the role of COM. The useful parts of AUTOSAR are the communication
*semantics*; the unpleasant parts are the thick, heavily-configurable middleware
that implements them. blobly keeps the semantics that earn their keep — generated,
lock-free, no-alloc — and skips the rest.

> We name things in blobly terms (Loom, FB, handler, IOC); AUTOSAR terms appear
> here only to compare. The good RTE idea — **typed ports + a coherent input
> snapshot per runnable** — is exactly blobly's core model.

## What we have, what AUTOSAR has

| Pattern | AUTOSAR (RTE / COM) | blobly | Status |
|---|---|---|---|
| Implicit sender-receiver — coherent input snapshot in, outputs committed out | `Rte_IRead` / `Rte_IWrite` | Loom snapshots the In ports before the handler, publishes Out after | ✅ have (it's the core model) |
| Last-is-best data semantics | S/R "data" element | IOC seqlock / double / triple | ✅ have |
| Typed ports | PortInterface / data elements | generated `In`/`Out` port structs | ✅ have |
| Periodic trigger | `TimingEvent` | `on_<period>` handler | ✅ have |
| Per-runnable private state | Inter-Runnable Variables (IRV) | the FB's private struct | ✅ have |
| Deadline / alive timeout, init value, invalidation | COM rx monitoring | COM rx deadline → `valid = false` | ✅ have |
| Transmission modes (cyclic / on-change / mixed, min-delay) | COM tx modes + filters | `[[frame]].tx` | ✅ have |
| Raw↔physical scaling at the boundary | RTE/COM data conversion | DBC codec in the bridge | ✅ have |
| Diagnostics request/response | DCM/DEM over the RTE | ISO-TP + UDS at the bus | ✅ have |
| Queued (event) sender-receiver — discrete events, none dropped | `Rte_Send`/`Rte_Receive`, `isQueued` | — (IOC is last-value) | 🔜 planned |
| React on reception, not on a clock | `DataReceivedEvent` | — (handlers are cyclic) | 🔜 planned |
| Mode management (gate handlers / reconfigure by ECU state) | ModeDeclarationGroup, `ModeSwitchEvent` | — (only NM sleep/wake) | 🔜 planned |
| End-to-end protection (CRC + alive counter) | E2E library / transformer | `comm/e2e` (CRC-8 J1850 + 4-bit counter + data id), per-frame `[[frame]].e2e` | ✅ have |
| Synchronous service call between components | Client-Server (`Rte_Call`) | — | 🚫 skip |
| RTE-managed critical sections | ExclusiveArea | — | 🚫 skip (by design) |
| Multiple instantiation, connector remap, port-defined arg values | RTE config surface | — | 🚫 skip |
| Atomic multi-signal update | COM signal groups / shadow buffers | per-PDU pack | 🚫 skip (PDU pack already atomic) |
| Measurement & calibration | MCD / XCP | — | 🚫 skip (separate concern) |

## Why the planned ones are missing (and what they'd take)

- **Queued (event) S/R.** The IOC overwrites, so if the producer writes faster than
  the consumer reads, **intermediate writes are dropped** (you never lose the
  *latest* value — only the ones in between, and only when the writer outpaces the
  reader). That's exactly right for *state* (the newest speed wins) but lossy for
  *events* where each occurrence matters — a button edge, a one-shot command, a fault
  *occurrence*, a tick counter. It's absent because the no-alloc default favoured a
  fixed last-value cell. Adding event retention is a fixed-size **SPSC ring**[^spsc]
  per event channel — still single-writer, still lock-free, still no-alloc, just
  FIFO-retaining instead of overwriting. A ring is still *bounded*: if the consumer
  falls behind, it fills and must drop (oldest/newest) and **raise an overflow flag**
  — designed, detectable loss instead of silent per-cycle drops.
- **Data-received triggering.** Everything is cyclic today (`on_10ms` reads the
  latest), so a handler reacts within one period rather than on arrival. A
  `on_<signal>_received` handler (the natural partner to queued events) closes that
  latency gap. Missing only because we built the cyclic path first.
- **Mode management.** There's no general ECU-mode concept yet (NM gives sleep/wake
  only). It's lean to add — a *mode* is just a signal the Loom consults before
  dispatch, gating which handlers run and which TX modes apply. Missing because no
  example has needed state-dependent behaviour yet.
- **E2E protection.** ✅ **done.** Signals had validity but no integrity; `comm/e2e`
  adds a CRC + alive counter so a receiver detects corruption, repetition, a stuck
  sender, and (with the rx deadline) loss — a real ISO 26262 need. It's a generated
  stamp/check on a `[[frame]]` at the COM boundary, **independent of the transport**
  (it works on the raw frame bytes, over last-value *or* queued — it is *not* the
  same thing as the SPSC ring). `examples/overspeed` protects its `LampFrame`; the
  test recomputes the CRC independently and checks the counter advances.

## Why the skipped ones stay skipped

- **Client-Server / RPC** — the model is dataflow; the request/response that matters
  (diagnostics) is handled at the bus by UDS. Intra-ECU RPC adds call/timeout
  semantics for little gain; reach for it only if a concrete need appears.
- **Exclusive areas / locks** — the entire point of the IOC is *never spin*. Hard skip.
- **Multiple instantiation, connector remap, port-defined arg values** —
  over-engineering for codegen-from-one-config where every FB and wire is explicit.
- **Signal groups** — per-PDU packing already gives frame-level atomicity.

The line we hold: borrow a semantic only when it **extends** the model, lock-free and
no-alloc. That keeps blobly a lean alternative instead of a re-implementation of the
thing it avoids.

[^spsc]: **SPSC ring** = *single-producer, single-consumer ring buffer*: a fixed array
    with a producer-owned head index and a consumer-owned tail index (both atomic),
    so one writer enqueues and one reader dequeues with no locks and no allocation.
    It's the standard lock-free queue, and it matches the IOC's existing
    single-writer-per-channel rule — it just keeps a short FIFO of values instead of
    overwriting to the latest.
