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
| Periodic trigger | `TimingEvent` | `[[fb.handler]] period_ms` (the `on_<period>` name is convention, not syntax) | ✅ have |
| Per-runnable private state | Inter-Runnable Variables (IRV) | the FB's private struct | ✅ have |
| Deadline / alive timeout, init value, invalidation | COM rx monitoring | COM rx deadline → `valid = false` | ✅ have[^host] |
| Transmission modes (cyclic / on-change / mixed, min-delay) | COM tx modes + filters | `[[frame]].tx` | ✅ have[^host] |
| Raw↔physical scaling at the boundary | RTE/COM data conversion | DBC codec in the bridge | ✅ have[^host] |
| Diagnostics request/response | DCM/DEM over the RTE | ISO-TP + UDS at the bus | ✅ have |
| Network management — coordinated bus sleep/wake | CanNm / NmIf | `comm/nm` + `[nm]` endpoint bindings (request/release, cluster listen, bench-verified) | ✅ have |
| Cross-core communication in one ECU | OS-Application partitioning + the OS **IOC** + per-core RTE config | an ordinary `[[signal]]` whose endpoints sit on different cores; the generator derives the transport (xioc) and emits an image per core from ONE config ([multi-image.md](multi-image.md)) | ✅ have |
| Runtime observability — thread/ISR/handler trace, per-handler timing, CPU load | ARTI/ORTI + vendor tracing tools, DLT | per-core flight recorder → multi-core swimlane, `stat` (per-handler last/max/mean µs), CpuLoad telemetry — all config-wired, dumped over the bus | ✅ have |
| Queued (event) sender-receiver — discrete events, none dropped | `Rte_Send`/`Rte_Receive`, `isQueued` | — (IOC is last-value) | 🔜 planned |
| React on reception, not on a clock | `DataReceivedEvent` | — (handlers are cyclic) | 🔜 planned |
| Mode management (gate handlers / reconfigure by ECU state) | ModeDeclarationGroup, `ModeSwitchEvent` | — (only NM sleep/wake) | 🔜 planned |
| End-to-end protection (CRC + alive counter) | E2E library / transformer | `comm/e2e` (CRC-8 J1850 + 4-bit counter + data id), per-frame `[[frame]].e2e` | ✅ have |
| Authenticated messaging (MAC + freshness, anti-replay) | **SecOC** | `comm/secoc` (AES-128 **CMAC** + freshness), per-frame `[[frame]].secoc` | ✅ have |
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
  adds a CRC + alive counter so a receiver detects corruption (CRC), repetition / a
  stuck sender (counter `delta == 0`), individual lost frames (counter skip,
  `delta > 1` → `lost`), and loss-of-communication (the rx deadline) — a real ISO
  26262 need. It's a generated
  stamp/check on a `[[frame]]` at the COM boundary, **independent of the transport**
  (it works on the raw frame bytes, over last-value *or* queued — it is *not* the
  same thing as the SPSC ring). `examples/overspeed` protects its `LampFrame`; the
  test recomputes the CRC independently and checks the counter advances.
- **SecOC.** ✅ **done.** E2E's *security* sibling: same wrap-on-tx / check-on-rx
  shape, but the unkeyed CRC becomes a **keyed AES-128 CMAC** and the counter
  becomes a **freshness value** (anti-replay). E2E stops *nature* (random faults,
  ISO 26262); SecOC stops a *person* (spoofing / tampering / replay, ISO-SAE
  21434) — only a key holder can forge the MAC. `comm/secoc` is unit-tested against
  the FIPS-197 (AES) and RFC 4493 (CMAC) vectors; `examples/overspeed` authenticates
  a `SecureFrame`. The real cost over E2E isn't the wiring (identical) — it's the
  crypto primitive and **key + freshness management** (distribution, sync,
  monotonicity across resets), which a production deployment must own.

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

[^host]: On the host COM bridge. The lean ThreadX target codec generates cyclic tx and
    the trivial signal layout only for now — richer layouts, rx deadlines, and tx modes
    on target fail generation loudly rather than half-work (see
    [um/add-a-signal.md](um/add-a-signal.md)).

[^spsc]: **SPSC ring** = *single-producer, single-consumer ring buffer*: a fixed array
    with a producer-owned head index and a consumer-owned tail index (both atomic),
    so one writer enqueues and one reader dequeues with no locks and no allocation.
    It's the standard lock-free queue, and it matches the IOC's existing
    single-writer-per-channel rule — it just keeps a short FIFO of values instead of
    overwriting to the latest.
