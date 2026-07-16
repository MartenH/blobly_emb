# Bootloader — design + build log

> Status (2026-07-13): **P1+P2 DRY-CODED AND SIM-VERIFIED** — no silicon run yet.
> Requirements: `requirements/boot.toml` (draft; REQ-BOOT-001/002/004/005/008/009
> exercised by tests + the vcan end-to-end). Built so far:
> - `boot/` — header contract + CRC-32 + decision (`boot.v`), the UDS programming
>   session 0x27/0x31/0x34/0x36/0x37/0x11 over FlashOps hooks (`prog.v`); unit
>   tests cover the happy path, corrupt transfer, region protection, sequence guards.
> - `examples/boot_sim` — the SAME session on vcan0 (rx 0x7B0 / tx 0x7B8), flash =
>   a file, one run = one power cycle. Verified against blobly_net `cmd/flash`:
>   fresh→stay_boot, flash→run_app, power-cycle persistence, corrupt→stay_boot,
>   recovery reflash→run_app.
> - `tools/mkimage` — wrap a .bin in the header (`--valid` factory / `--pad-vectors`
>   target layout); blobly_net `cmd/flash` = the host flasher (BLBT passthrough).
> - `examples/h755_boot` + `boards/h755zi/{flash.c,bootmap.h}` — the TARGET SKELETON:
>   compiles freestanding (25 KB, fits sector 0), **flash.c dry-coded from RM0399,
>   bench-unverified** — the P1/P2 hardware pass is the next step when a board is back.

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

## The handoff, both directions

**Boot → app: the jump only ever happens from near-reset state.** On the happy path
boot has touched NOTHING before deciding — no PLL, no CAN, no interrupts enabled;
reading a RAM cell and CRC-ing flash needs only reset defaults. So the direct jump is
clean by construction: set VTOR to the app's vector table, load MSP from its word 0,
jump to its reset vector. The app is linked at the app-region base and its startup is
unchanged; any later reset lands back in boot by hardware (boot owns the boot address).

The one state-laden case — after a programming session (CAN up, clocks configured,
a diagnostic session to tear down) — **never jumps**: it writes its result and
self-resets, and the next cycle takes the virgin happy path. Peripheral-state leakage
into the app is eliminated by construction, not managed by a deinit checklist.

**App → boot** is the request cell above; **information forward** is its sibling: a
`boot_info` no-init cell (boot reason — normal / freshly-flashed / was-invalid,
bootloader version) written by boot before the jump, exposed by the app over a
DID/shell command without re-deriving anything. Both cells live in one board-owned
header (the `duo.h` pattern) and are bound in `[boot]` so generator, app, and boot
manager cannot disagree on the addresses.

**Dual-bank caveat for P4:** a full-bank swap swaps the bootloader out with the app —
so bank-swap activation means either boot duplicated at the base of BOTH banks, or
no-swap with per-bank-linked images and a boot-side bank choice. Named now, decided
in P4 with the silicon on the bench.

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

## Entering programming mode — production practice vs this stack

Production bootloaders wrap the entry and the session in layers this stack
implements partially (by design — each deferred layer has a named seam). The
map, so nobody mistakes the bench workflow for the field workflow:

**1. Pre-conditions (before entry).** An OEM application refuses the switch to
programming mode unless the vehicle state allows it — speed = 0, engine off,
battery voltage in a safe window, transmission in park — answering NRC 0x22
(conditionsNotCorrect) otherwise. In this stack the entry request is the app's
`boot` shell command (bootcell + reset), and today it is UNCONDITIONAL — a
bench tool. The gate belongs to the application layer (only the app knows its
state model), which is exactly the mode-management seam: a production app
gates the bootcell write on its own safe-state signal (REQ-BOOT-015 names
this; the boot manager itself cannot know vehicle state and never will).

**2. Entry strategy.** The two production shapes are unlock-the-app-first
(0x27 to the application, then 0x10 02 triggers the reset) and
authenticate-in-boot (free transition, locked bootloader). This stack is the
second shape: the app's entry path carries no authentication, and every
write/erase service in the boot refuses (NRC 0x33) until the in-boot
SecurityAccess handshake passes. A production deployment layering UDS into
the application would likely move to the first shape — the bootcell transition
flag is already the mechanism both shapes share.

**3. Session discipline (ISO 14229 timers).** The programming session dies
after 5 s of tester silence (S3server, REQ-BOOT-013): back to the default
session, security re-locked, a half-done download abandoned. And a boot
entered BY REQUEST over a valid app returns to the application after a
bounded quiet window (REQ-BOOT-014) — a dead tester must not park the ECU in
boot until power-off. TesterPresent (0x3E) keeps a session alive through
longer tester-side pauses.

**4. Authentication (0x27 today, 0x29 at P5).** The seed/key here is a
placeholder pair sharing one function with the host (`expected_key` — the P5
replacement point). Production practice: a DEDICATED security level for
flashing (distinct from any application diagnostics level), and increasingly
UDS 0x29 Authentication — a PKI challenge/response (the tester signs the
ECU's random challenge; the boot verifies against an OEM public key in
protected storage) per ISO/SAE 21434 expectations. P5 (REQ-BOOT-011) covers
both rungs: real seed/key material first, 0x29 + signed images when a
deployment demands them.

**5. The last line: image verification before the mark.** Independent of any
session security, the check routine (0x31 FF01) hashes the flashed image and
only THEN writes the valid mark — today a CRC-32 (integrity), at P5 a
cryptographic signature (authenticity), same choreography. A tester that
somehow bypassed every session barrier still cannot make the boot manager run
an image that fails this check; a torn or tampered transfer leaves an invalid
header the decide() path refuses forever.

## Bench log — NUCLEO-H755ZI-Q, 2026-07-15 (first silicon pass)

The dry-coded chain, end to end on the H755 bench (ST-LINK + PCAN, classic 500 k):

- **P1 jump**: boot at sector 0, `mkimage --valid --pad-vectors` app at APP_BASE —
  header magic + CRC over 50 KB verified, VTOR/MSP/jump; the full ThreadX app
  (both cores, NM, telemetry, NvM persist) runs linked at `APP_VECTORS`. The app
  side is one make flag: `make APP_LINK=boot` (defsym-driven FLASH origin).
- **app→boot rung**: the `boot` shell command writes the SRAM4 request cell and
  resets; the response is deliberately lost to the reset (0x11-style — silence is
  the ack). Boot takes the request and stays.
- **P2 CAN reflash**: session → seed/key → UDS erase (0x31 FF00, real 128 KB
  sector) → 50 956 bytes in 100 ISO-TP blocks → on-target full-image CRC (0x31
  FF01) → valid mark written → reset → the delivered app runs.
- **Pull-power mid-transfer**: flasher killed ~30 blocks in, board reset — the
  torn image (header landed, tail missing, no valid mark) is REFUSED, boot stays,
  bus silent; recovery = plain reflash from programming mode → app runs.
- **Bootcell**: NVIC-reset survival (request honored) and POR/stale-garbage
  rejection (fresh flashes jump straight to the app) both observed.

Dry-code gaps the bench found (all fixed in this pass):
1. Boot never muxed PD0/PD1 (`board_can_clock_pins_init` — `blob_can_open` does
   clocks, not pins): programming session timed out into a dead wire.
2. `Prog.seed`'s struct-field default ('BLOB') is `_vinit` work that freestanding
   never runs — the __global read seed 0, the tester took the already-unlocked
   convention and skipped the key, every guarded service NRC'd 0x33. Third
   sighting of the vlang `_vinit` trap; seed is now assigned explicitly.
3. Host side: SocketCAN's default `txqueuelen 10` drops the ISO-TP burst
   (`No buffer space available`) — `ip link set can0 txqueuelen 1000`.

Known polish (not blocking): the 0x11 positive response is lost to the immediate
reset (drain the Tx FIFO first); `st-flash erase` mass-erases — never use it for
a single sector on a populated part.
