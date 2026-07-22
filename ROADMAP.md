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

## Multi-node & platform

- ✅ **Dissolution P1/P2b** — `system.toml` composes nodes; sysgen/syscheck
  cross-node validator; multi-DBC gateway runs on two vcans
- ✅ **Multi-image (AMP)** — `[[partition]] image=` generates the satellite; cross-
  core signals as xioc slots; H755 CM4 bench-verified
- 🧭 **On-silicon multi-node** — domain (H755) + gateway (H735) + zone (H723) from
  one `system.toml`, a signal across the real bus (**gated on H723 CAN wiring**)

## Observability

- ✅ **Trace** — config-driven trace as a COM module; ThreadX thread/ISR capture;
  dumped over FDCAN (never semihosting in the data path)
- ✅ **CAN shell** — 0x7F0 command channel + GUI panel

---

## Hardware bench

| Board | Role | Debug | CAN | Notes |
|-------|------|-------|-----|-------|
| STM32H755ZI-Q | domain (AMP CM7+CM4) | ✅ up | ✅ FD Click | FD payload validation target |
| STM32H735G-DK | gateway | ✅ up | ✅ on-board | 25 MHz FDCAN kclk |
| STM32H723 | zone | ✅ up | ⛔ needs soldering | flash-ready; CAN pending |
| PCAN-USB | host bus view | — | 🔨 `can0/can1` | passwordless bring-up via `blobly-can` |

`openocd` 0.12 segfaults with the STLINK-V3s → use `st-flash` (by `--serial`).

---

## Immediate (this prep day → the away days)

Driver-format completeness is **done in sim**: ext-id (`#180`), CAN-FD payloads
(`#181`), signal-route ext destinations (`#182`) — all merged. Passwordless CAN
bring-up (`blobly-can`) is installed. Remaining:

1. 🧪 **On-silicon validation** (bench): flash the H755 CAN-FD echo (`#181`) + send
   a 64-byte FD frame; re-check H735 ext-id (`#180`). Gated on CAN wiring.
2. ⏭️ **Cross-core xioc routes** — the next substantial codegen item.
3. 🧭 Follow-ups: generated-target FD data-timing harmonization (bench-gated);
   canif FD recv-flag; wire H723 CAN for the 3-node silicon run.

Public-repo gate: `blobly_net` GPL→MIT (net#57) before the site/docs go public.
