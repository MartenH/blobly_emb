# Bootloader — design sketch

> Status: SKETCH (2026-07-13). Requirements: `requirements/boot.toml` (draft, deriving
> from SYS-REQ-PROG-001). Nothing is built yet; this page is the shape to argue with.

## Goal

In-field application update over the diagnostic transports, unbrickable at every step.
**CAN (ISO-TP) is the first transport binding; nothing in the design may close the door
on Ethernet (DoIP)** — the same rule the trace dump already lives by: end-of-stream and
structure live in the FORMAT and the SERVICES, never in a transport's timing or framing.

## Shape: a small immutable boot manager + the blobly stack it already has

Two pieces, not one:

```
flash ┌────────────────┬──────────────────────────────────────────┐
      │ boot (≤32 KB)  │ application image(s)                     │
      │ never updated  │ [header | vectors | code ...]            │
      │ in the field   │ header: magic, length, crc, version, ... │
      └────────────────┴──────────────────────────────────────────┘
```

- **boot** — a bare-metal V freestanding image (no ThreadX, one superloop: exactly the
  shape `examples/h735_app` already proves). It owns the boot decision, the flash
  driver, and the programming session. Small enough to review, boring enough to never
  touch again (REQ-BOOT-008: the app-update flow cannot write its region).
- **application** — any blobly image as built today, plus an **image header** the build
  emits and the boot manager verifies.

Reuse, not invention: `driver/can` + `comm/isotp` + `comm/uds` are the programming
stack; the boards layer owns flash geometry/erase/program (a `boards/<b>/flash.c` the
way clocks/pins are owned today); ecu.toml grows a `[boot]` block bound by loom2v like
every module (`docs/com-modules.md` rules).

## Boot decision (REQ-BOOT-001/002/003/010)

```
reset → boot manager:
  1. programming request pending?   (magic in a no-init RAM cell, written by the app,
     └─ yes → stay in bootloader        cleared on read — the dtrace-cell pattern)
  2. app header valid && crc ok?
     └─ no  → stay in bootloader    (REQ-BOOT-002: never jump into half an image)
  3. jump to app                    (bounded delay: no bus wait on the happy path)
```

The app side of (1) is one UDS service the application already speaks: `EcuReset /
programming session` → write the request cell → reset. That is REQ-BOOT-003 with no
new machinery — the request cell is the SRAM4-handshake pattern from the dual-core
work, aimed at a reset instead of a second core.

## Programming session (REQ-BOOT-005/006/009)

Plain UDS, because it is already transport-neutral by construction:

| step | UDS service | notes |
|---|---|---|
| enter | 0x10 programming session | boot manager answers; app forwards + resets (above) |
| identify | 0x22 read DID | bootloader + app version/validity (REQ-BOOT-009) |
| unlock | 0x27 security access | seed/key; the hook where REQ-BOOT-011 lands |
| erase | 0x31 routine: erase region | region = app area only (REQ-BOOT-008 enforced here) |
| transfer | 0x34 / 0x36 × N / 0x37 | block-wise, per-block ack (ISO-TP flow control does the pacing on CAN; DoIP brings its own) |
| verify | 0x31 routine: check image | full-image CRC (+ signature when REQ-BOOT-011 lands) — only THEN is the header's valid mark written (REQ-BOOT-005) |
| go | 0x11 ECU reset | boot decision runs again, now finds a valid image |

`comm/uds` today serves DIDs; the bootloader adds 0x10/0x27/0x31/0x34/0x36/0x37/0x11 —
services the host side (`cantester_v` heritage in blobly_net) already knows how to
drive. The host flasher is a blobly_net `cmd/` tool speaking the same modules.

**Transport neutrality in practice:** the boot manager talks to `uds.Server` through
the same endpoint-binding seam every ComModule uses. ISO-TP/CAN is binding #1; a DoIP
binding is a second transport handing the same byte streams to the same server —
blobly_net already carries a `doip` module for the host half. No service, block
format, or session state may reference frame sizes or bus timing (REQ-BOOT-006);
block size is the transport binding's business, exactly like the trace dump's
`pack_chunk(cap)`.

## Atomic activation (REQ-BOOT-007) — two strategies, one requirement

The requirement is instance-agnostic; the boards layer picks the strategy the silicon
affords:

- **Dual-bank parts (H755, H743...):** program the inactive bank, verify, then flip
  the bank-swap option bit — activation is one atomic hardware bit; rollback is
  flipping it back. The H755 bench board is the natural first target.
- **Single-bank parts (H735):** erase-then-program in place; "atomic" degrades to
  "valid mark written last" — an interrupted update leaves an invalid header, the boot
  manager keeps the ECU in programming mode (REQ-BOOT-004), and the previous app is
  gone but the ECU is not bricked. Honest, documented downgrade — same rule as the
  lean codec: fail loudly, never half-work.

## Image header (the contract between build and boot)

Emitted by the build (objcopy step or a tiny host tool), verified by boot:

```
magic | header_ver | image_length | crc32 | sw_version | entry | [signature (BOOT-011)]
```

Written into a fixed slot at the front of the app region; the CRC covers everything
but the header itself; the valid mark is the LAST thing the programming session
writes. `[boot]` in ecu.toml binds the request-cell address, app region, and DIDs so
the generator keeps bootloader and app agreeing on the layout — one config, as always.

## Phasing (each rung bench-verified, as usual)

1. **P1 — boot manager skeleton** on the H755: header check + jump + request cell;
   no comms yet. Proves the layout and the decision logic.
2. **P2 — CAN programming session**: ISO-TP + UDS erase/transfer/verify on the bench;
   host flasher tool in blobly_net. First real reflash over the wire.
3. **P3 — app-side handoff**: programming session request from the running
   application (NM-aware: hold the bus awake during the session).
4. **P4 — dual-bank atomic activation** on the H755 (+ the single-bank degrade
   documented on H735).
5. **P5 — authenticity** (REQ-BOOT-011): CMAC first (comm/secoc precedent, key
   management honestly out of scope), asymmetric signature when it earns its way in.
6. **Ethernet/DoIP binding** when hardware with Ethernet lands — by construction a
   new binding, not a redesign.

## Non-goals (now)

- Bootloader self-update (field-updating the updater — needs the dual-image dance
  applied to boot itself; revisit when a real deployment demands it).
- Delta/compressed updates, multi-image orchestration across cores (the satellite
  image rides the owner's flash banks for now).
- Production key management (P5 notes the seam; a deployment owns the keys).
