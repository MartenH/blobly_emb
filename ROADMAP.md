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
- ⏭️ **Cross-core routes (xioc)** — a route whose source/dest buses live on
  different cores; approved implicit-xioc-slot model, reuses multi-image plumbing
- 🧭 **Target multi-bus comm owner** — per-bus channel + Rx-ISR multiplexed into
  one core's comm thread, so routes run on real silicon (today the ThreadX comm
  thread rejects routes)
- 🧭 **ISO-TP / UDS** — beyond the boot-loader's request path into a general
  diagnostic service layer
- 🧭 **Cross-core BULK transport** — today a cross-core signal is capped at one
  xioc cell (1–2 × `u32` = 8 B); anything larger has no generated path and must be
  hand-written as a shared-memory owner-buffer + request/ack handshake (the one
  worked example is the dtrace handoff in `boards/h755zi/duo.h`, 2 KB in SRAM4).
  A "bulk signal" — declared in `ecu.toml`, generated on both sides, paced like
  the trace dump's `pack_chunk` — is the missing rung. Note the constraint that
  makes it non-trivial: the cores don't arbitrate LDREX/STREX, which is why xioc
  is plain-store wait-free (the triple buffer tore 162/200k across cores), so a
  wider cell is a design problem, not a bigger constant. See
  [docs/um/move-data.md](docs/um/move-data.md).
- 🧭 **Bulk transport benchmark** — extend the `tools/ioc_bench` family (which
  measures the small-signal IOC/xioc path) with a THROUGHPUT harness: bytes/s and
  latency for a cross-core owner-buffer handoff vs the same payload over ISO-TP,
  so the "how big before it should leave the chip" answer is measured rather than
  assumed.

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

## Immediate (this prep day → the away days)

Driver-format completeness is **done in sim**: ext-id (`#180`), CAN-FD payloads
(`#181`), signal-route ext destinations (`#182`) — all merged. Passwordless CAN
bring-up (`blobly-can`) is installed. Remaining:

1. ✅ **On-silicon validation** (bench) — 64-byte CAN-FD payloads verified on the
   H755, H735 ext-id re-checked, H723 echo brought up (`#184`). BRS at 2 Mbit from
   the 8 MHz kclk goes bus-off (only 4 tq); FD payloads verified without BRS.
2. ⏭️ **Cross-core xioc routes** — the next substantial codegen item.
3. 🧭 Follow-ups: generated-target FD data-timing harmonization (bench-gated);
   canif FD recv-flag; the 3-node silicon run (all boards now wired).
4. ⏭️ **CI** — this repo has none. 17 V test files, `make check` and `make trace`
   run only by hand, so nothing gates a PR.

Public-repo gate: **cleared** — `blobly_net` is MIT from its initial commit
(relicensed 2026-07-22, history rewritten), so the site/docs are unblocked.
