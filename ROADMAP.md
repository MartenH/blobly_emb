# blobly_emb — Roadmap

A V-language automotive ECU stack: no-alloc, sim-first, codegen from `ecu.toml` /
`system.toml`, ThreadX on target, CAN-FD-first. This file is the forward-looking
"what's coming"; shipped detail lives in git history and `docs/`.

Status keys: ✅ shipped · 🔨 in progress · ⏭️ next · 🧭 planned · ⛔ blocked

---

## Consolidation → one reference system  🔨

The example count (~45 dirs) has outgrown its usefulness — most are single-feature demos and a
maintenance burden. GOAL: grow **`examples/system_full`** into the ONE reference system that
exercises every shipped feature across its three real nodes, and **retire the one-offs as each
feature lands there**. Net fewer examples, and one integration test that actually means something.

The three nodes (all on the bench, one `system.toml`):
- **domain** (H755, dual-core) — AMP: a CM4 co-processor streaming into a cross-core `[[bulk]]`
  pool the CM7 control loop consumes; cross-core signals (xioc); `[shell]` (bulkperf/ps/bmc);
  two-core trace; nm; nvm/persist. *Absorbs* h755_threadx, h755_m4_app, gw_xcore, trace_multicore.
- **sysnode** (H735, gateway) — 2-bus routing (done) + protected routes (E2E/SecOC), ext-id,
  CAN-FD payloads, and the eth/SOME-IP stack on its Ethernet. *Absorbs* gw_*, h735_net/someip/doip.
- **zone_a** (H723, edge) — a producer node + IO (GPIO/ADC/PWM). *Absorbs* io_*, h723_*.

Rungs — each folds a feature-set AND retires the matching examples, one reviewable PR:
1. 🔨 **domain dual-core** (`#235`, bench-verified) — CM4 co-processor satellite + cross-core
   `[[bulk]]` "model" stream + `bulkperf` (28 MB/s over CAN) + cross-core **CpuLoad** (both cores
   in the frame) + `[shell]` + nvm/persist `DriveMode` + the NM cluster it needs. Fixed two real
   loom2v bugs: a single-thread satellite registered no FBs (ran an empty scheduler) and the
   matching state-struct name mismatch. Retiring h755_threadx/h755_m4_app waits for rung 2.
2. 🧭 **domain two-core trace + xioc signals** — incl. fixing the owner-FB cross-core-signal read
   (emits host-only `osal.ioc_acquire2` for the target today) → retire trace_multicore, gw_xcore,
   then h755_threadx + h755_m4_app
3. 🧭 **domain nm + nvm/persist** (nm + persist already landed in rung 1)
4. 🧭 **zone_a IO** (GPIO/ADC/PWM) → retire io_*
5. 🧭 **sysnode protected routes + ext-id + FD payloads** → retire gw_*
6. 🧭 **sysnode eth + SOME/IP + DoIP** — incl. a DoIP diagnostic over Ethernet that reads/writes
   the persisted NvM data (e.g. `DriveMode`), tying the networking node to persistence → retire
   h735_net/someip/doip

Kept standalone (not features of a running system): `bulk_bench` (host micro-bench), `minimal`.

---

## Communication stack

- ✅ **COM TX modes** — cyclic / on-change / on-write, DBC-driven codegen
- ✅ **Routing P2a/P2b** — signal routes (decode → re-encode) and frame routes
  (raw PDU forward) with a full-contract firewall
- ✅ **Protected routing P2c** — E2E (CRC+counter) and SecOC (AES-CMAC) re-protect
  on re-encode, and source-verify on ingest
- ✅ **Extended-id (29-bit)** — `#180`, all 5 driver backends, id-width-exact rx
- ✅ **CAN-FD payloads (DLC>8)** — `#181`, fdcan M_CAN backend (FD DLC-codes/FDF/
  BRS + 64-byte message-RAM elements); **on-silicon H755 FDCAN validation still
  pending the bench**
- ✅ **Signal-route extended destinations** — `#182`, a signal route re-encodes
  into a 29-bit dest frame; candb attribute index keyed by (id, ext)
- ✅ **Cross-core signal routes** (`#199`+P2) — a signal route whose buses sit on
  different cores lowers to an IOC crossing: cfg2v allocates the channel, the source
  bridge publishes the decoded f64, the destination bridge composes + transmits on
  its own channel. Frame routes cross-core are a CONTRACT error (REQ-TOPO-010 —
  a raw PDU is bulk's job). vcan-verified (`examples/gw_xcore`); silicon in the
  bench queue
- 🧭 **Target multi-bus comm owner** — per-bus channel + Rx-ISR multiplexed into
  one core's comm thread, so routes run on real silicon (today the ThreadX comm
  thread rejects routes)
- 🧭 **ISO-TP / UDS** — beyond the boot-loader's request path into a general
  diagnostic service layer
- ✅ **Wide cross-core signals** (`#211` — the derivation rung; **REQ-INV-006
  itself stays draft/covered**, closing only when the #212 shapes land and the
  silicon review signs off) — a remote signal carries ≤16 fields of
  `u32`/`u16`/`u8`/`bool` as u32 lanes (`xioc_n`), pair cell preserved; layout
  REQ/ACK handshake makes a stale/restarting satellite read as never-fresh,
  never as cross-talk. Residue: the #212 packing decision (u64/signed/float/
  packed-narrow + local/remote encode unification, **user call**); H755 tear
  re-run at wide widths bench-queued (`wide-xioc-derivation-and-silicon`).
- ✅ **Bulk P1 portable core** (`#213`, REQ-BULK-001..003) — `boards/common/bulk.h`
  pool + SPSC descriptor rings, fallible counted loans, host-proven cross-process
  (fork+`MAP_SHARED`); `bulk-ring-silicon` closed on the H755 (`#228`, below).
- ✅ **Bulk cross-core `ecu.toml` surface** (`#225`) — a `[[bulk]]` whose
  producer/consumer sit on different cores is placed in the H755 shared window (both
  images derive the same pointer from a board seam `xcore_bulk_base()`, deterministic
  32 B-aligned offsets, static-checked vs the region budget); each image emits the
  pools it is an endpoint of; the cross-partition guard allows cross-**core** and
  rejects same-core cross-partition (host has no backend); `[[bulk]]` schema added.
  **Bulk is an OS-thread/platform job, never an FB** (settled) — the consumer is a
  service thread; until an `osal.bulk` transport exists, bulk termination stays in a
  platform module and the app never touches the pool.
- ✅ **Bulk on-silicon** (`#228`) — `examples/h755_threadx` `[[bulk]]` "xfer": the M4
  produces seq-tagged 256 B blocks, the CM7 comm thread consumes + verifies. loom2v
  emits per-image service hooks (`xcore_bulk_produce/consume`, like `xcore_trace_service`);
  the platform glue owns the pool. Bench: **rx_bad = 0** over 32k+ blocks (byte-exact,
  no tearing across the AXI fabric) and rx_ok + rx_gap == tx_seq (every attempt
  consumed or a counted backpressure drop). Closes `bulk-ring-silicon` / REQ-BULK-003.
- ✅ **Bulk HSEM doorbell** (`#230`) — the CM4 rings HSEM sem 0 after each publish →
  IRQ125 on the CM7 → the ISR wakes the comm thread, so it drains on publish instead
  of polling. (A plain SW interrupt can't cross cores; HSEM is the H755's inter-core
  doorbell — no IPCC.) Bench: eliminated the backpressure drops (tx_full ~50% →
  ~0.2%). Also extended the shared vector table to the full IRQ range (was truncated
  at IRQ61 — an unexpected high IRQ jumped into `reset_handler`).
- ✅ **Bulk capability split** (`#231`) — the generated cross-core wrappers are
  role-restricted per image (producer: init/loan/publish; consumer: valid/take/
  release), so a wrong-role call is a compile error.
- 🧭 **Next bulk rungs** — `osal.bulk` (a declarable service thread so an *app*
  partition can terminate bulk, in the region table with directional permissions),
  cache hooks, off-chip mapping (ISO-TP / SOME/IP-TP). **The M4-independent-reset race
  is NOT recovered** — unlike a latest-value signal, a bulk pool transfers ownership,
  so there is no safe partial state to re-attach to (decided 2026-07-26). A satellite
  restart shuts the system down instead — see *Fault handling & shutdown*.
- ✅ **Bulk transport benchmark** (`#216`) — `tools/bulk_bench` in `make bench`:
  the ring moves ownership at ~5 M transfers/s (0.3 µs median publish→take,
  pinned cross-core) and ~0.9–6 GB/s payload filled+consumed, vs ~3–10 ms of
  classic-CAN bus time per ISO-TP transfer — "how big before it leaves the chip"
  is now a measured number (classic-scoped; FD ISO-TP unimplemented, not
  extrapolated).

## Network management & boot

- ✅ **NM** — sleep/wake, NM-gated COM TX, in-sleep NvM flush choreography
- ✅ **Bootloader** — persist + boot chain + S3 + P5 asymmetric auth (Ed25519
  signed images, TRNG-gated 0x29), bench-verified on H755
- 🧭 **Boot P4 dual-bank** · 🧭 **P6 RDP2 lock**

## Drivers & IO

- ✅ **CAN port ABI** — socket (host), fdcan (M_CAN bare-metal), ST-HAL, CanIf
  (AUTOSAR); format flags for FD + extended id
- ✅ **IO** — GPIO + ADC + PWM, silicon-verified; `make hwtest` on-target group
- ⏭️ **sthal / CanIf FD** — carry the FD flag through the HAL + AUTOSAR backends
  (fdcan done on this branch)

## Ethernet middleware

- ✅ **SOME/IP P1** — codec/schema + codegen, E2E on silicon (H735 NetX)
- ✅ **SOME/IP in the system model** (`#248`) — a `[bus.*]` declares its **carrier**:
  `can` (frames, a `dbc`) or `someip` (a service's events, a `service` + `version`).
  Membership follows the wire: CAN by shared `interface`, someip **explicit** (a node
  names the bus, and its `[someip]` endpoint is held to the system's contract).
  syscheck checks writers/reachability on a someip bus like any other.
- 🧭 **`tcu` as a system node.** The model is ready; what is open is that the tcu's
  peer is the **bench tool at .190, not an ECU** — REQ-TOPO-001 wants every
  transmitted signal received by ≥1 node. A system needs a way to say "this endpoint
  is consumed off-system" before the eth node joins `system.toml` as a member.
- 🧭 **SOME/IP lowering.** system-scope `[[signal]]`s are lowered to CAN wiring only;
  a someip node still AUTHORS its eth wiring (`[someip]` + `[[frame]]`). Rejected
  explicitly today rather than half-generated.
- 🧭 **SOME/IP P2 rx** · 🧭 **tx-mode harness** · 🧭 **loom2v eth integration**
- ⏭️ **Ordinary networking from an application.** Today an FB can only emit a
  ≤64 B latest-value signal on an eth bus; everything else is platform glue
  owning a socket in `main.v`. That is the wrong line. **Streaming UDP, a TCP
  connection, and an app-initiated SOME/IP request/response are ordinary things
  an application does** — they should be first-class and config-declared, the way
  a signal is. Sending a **raw L2 Ethernet frame** is the genuinely special case
  and may stay special. Concretely missing: an app-facing stream/datagram
  endpoint kind, a target-side RPC *client* (we serve, we don't call), payloads
  past the 64 B PDU bound on the signal path, and dynamic peers (the peer is
  static config today). Must land without breaking the isolation rule that keeps
  FBs driver-free and testable — the endpoint is declared, the socket stays in
  the platform. See [docs/um/move-data.md](docs/um/move-data.md).

## Multi-node & platform

- ✅ **Dissolution P1/P2b** — `system.toml` composes nodes; sysgen/syscheck
  cross-node validator; multi-DBC gateway runs on two vcans
- ✅ **Multi-image (AMP)** — `[[partition]] image=` generates the satellite; cross-
  core signals as xioc slots; H755 CM4 bench-verified
- ✅ **On-silicon multi-node** (`examples/system_full`, `#224`) — domain (H755) +
  gateway (H735) + zone (H723), all three real ThreadX images from one `system.toml`,
  bench-verified: the H735 gateway forwards 3 layout-identical routes across two
  FDCAN buses (raw copy + id remap), closed loop observed on both buses. A new
  `boards/h723` + a `.blobnet` monitor project ride along.
- ✅ **Gateway/board hardening** (codex #224 re-review) — mostly landed: NM-gate on the
  gateway forwards (`#226`), effective destination-cadence validation + `boards/h723`
  bonded-pad map (`#229`), and the HSE-fallback path now HANGS rather than reprogramming
  SysTick (`#229`, see *Fault handling & shutdown*). Deliberately NOT done: the
  `-DTX_ENABLE_EXECUTION_CHANGE_NOTIFY` define on the system_full nodes — they don't
  enable `[trace]`, so the port never calls the hooks and gc-sections strips them;
  adding it would only waste cycles firing into an undumped ring.

## Fault handling & shutdown

**Open — there is no unified fault/shutdown design yet.** Fault paths currently resolve
independently, and *how an ECU should stop* (hang / reset / safe state) is undecided. Decisions
made and questions still open:

- ✅ **Clock bring-up fault** (`#229`) — `board_clock_fault()` HANGS deterministically (SWD reads
  the PC + RCC/PWR). An ECU on the wrong clock has already violated its real-time timing, and the
  FDCAN kernel clock rides the same HSE, so "limp to stay diagnosable" doesn't hold.
- 🧭 **M4 (satellite) independent reset** (decided 2026-07-26: *no recovery*) — a bulk pool is an
  ownership transport with no safe partial state to re-attach to (unlike a self-healing latest-
  value signal), so a satellite restart should take the whole system down: a **system reset of
  both cores**, cold-start. OPEN — the *mechanism*: (a) CM7-supervised (watch the CM4 boot-epoch/
  heartbeat in SRAM4, issue `NVIC_SystemReset`), or (b) hardware reset-domain coupling (RCC /
  option bytes route a CM4 reset to a system reset — needs an RM check). A watchdog catches a
  HANGING M4, not a resetting one.
- 🧭 **HSE-CSS** — arm the Clock Security System so a *runtime* crystal loss lands in the same
  stop path (hang / system reset) instead of a silent HSI downgrade. Touches the shared NMI
  vector; not bench-verifiable without physically killing the crystal.
- 🧭 **The general question** — pick the ECU fault model (hang, reset-loop, latched safe state,
  external watchdog) and make the above consistent with it, rather than per-path choices.

## Observability

- ✅ **Trace** — config-driven trace as a COM module; ThreadX thread/ISR capture;
  dumped over FDCAN (never semihosting in the data path)
- ✅ **Cross-core time correlation** (`#186`, REQ-TRACE-011) — a satellite core's dump
  block carries its measured clock offset + error bound, so a multi-core swimlane is
  one timeline instead of several. Measured per dump on the existing dtrace round
  trip; H755-verified at +49.7 ms, ±<1 ms
- ✅ **CAN shell** — 0x7F0 command channel + GUI panel

---

## Hardware bench

| Board | Role | Debug | CAN | Notes |
|-------|------|-------|-----|-------|
| STM32H755ZI-Q | domain (AMP CM7+CM4) | ✅ up | ✅ FD Click | FD payload validation target |
| STM32H735G-DK | gateway | ✅ up | ✅ on-board | 25 MHz FDCAN kclk |
| STM32H723 | zone | ✅ up | ✅ FD Click | echo silicon-validated (`#184`), 8 MHz kclk |
| PCAN-USB | host bus view | — | 🔨 `can0/can1` | passwordless bring-up via `blobly-can` |

`openocd` 0.12 segfaults with the STLINK-V3s → use `st-flash` (by `--serial`).

---

## Immediate (the away window, from 2026-07-23 — **no silicon access**)

The user is travelling: work must close on **host/sim alone** (vcan, fork/mmap AMP,
CI). Done since the last revision of this section: on-silicon driver validation
(`#184`, FD-without-BRS finding recorded above), and **CI exists now** — `#189`/`#190`
gate unit tests, `make lint`, `make check`, `make trace-check` (with the drift check)
and the example e2e tests on every PR and on pushes to `main` (the workflow's push
trigger is main-only; feature branches are gated via their PR).

**Host-only queue: CLEARED (2026-07-24).** Cross-core signal routes ✅ (`gw_xcore`
on two vcans), wide remote signals ✅ (`#211`), bulk P1 ✅ (`#213`) + measured
(`#216`), the full blind-merge codex backlog worked through (`#203` → 10 PRs
merged), CI hardened twice over (`#209`/`#215`). Remaining host items wait on
**user calls**: `#191` (trace raw-mode restore — also unblocks the
`trace_comm`/`trace_multicore` builds the CI gate skips) and `#212` (the wide
packing / encode-unification decision).

**Bench queue (on return):** xioc-route silicon check (H755); wide-width tear
re-run + layout REQ/ACK handshake on silicon (`wide-xioc-derivation-and-silicon`);
bulk ring on silicon (`bulk-ring-silicon`); FD data-timing harmonization; canif
FD recv-flag; target multi-bus comm owner → the **3-node silicon run**
(H755+H735+H723, all wired); REQ-TRACE-011 silicon sign-off.

Public-repo gate: **cleared** — `blobly_net` is MIT from its initial commit
(relicensed 2026-07-22, history rewritten), so the site/docs are unblocked.
