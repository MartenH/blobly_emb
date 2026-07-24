# blobly_emb — Roadmap

A V-language automotive ECU stack: no-alloc, sim-first, codegen from `ecu.toml` /
`system.toml`, ThreadX on target, CAN-FD-first. This file is the forward-looking
"what's coming"; shipped detail lives in git history and `docs/`.

Status keys: ✅ shipped · 🔨 in progress · ⏭️ next · 🧭 planned · ⛔ blocked

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
  (fork+`MAP_SHARED`); `bulk-ring-silicon` review bench-queued. Next rungs: the
  doorbell seam (H755 = **HSEM release-interrupt**, it has no IPCC), cache hooks,
  the `ecu.toml` surface, OSAL/IOC sanctioning before any app touches a pool.
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
- ⏭️ **On-silicon multi-node** — domain (H755) + gateway (H735) + zone (H723) from
  one `system.toml`, a signal across the real bus. **No longer gated:** all three
  boards are on CAN and the H723 echo is silicon-validated (`#184`)

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
