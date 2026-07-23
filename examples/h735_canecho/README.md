# h735_canecho — CAN on hardware (STM32H735G-DK, FDCAN1)

The second bare-metal example: drive **real CAN frames** through the register-level
FDCAN driver (`driver/can/can_fdcan.c`, no HAL). The board opens FDCAN1 and echoes
every **odd-id** classic frame it receives back on the bus with **id + 1** (so
`0x123 → 0x124`), and a bench tool sees a distinct reply for each frame it sends.
Even ids — which is what every reply is — are ignored: two echo nodes on one bus
would otherwise answer each other's replies forever.

```
main.v ──V -freestanding──▶ canecho.c ─┐
board.c (clock+pins) ──────────────────┼─ arm-none-eabi-gcc ─▶ canecho.elf ─▶ .bin ─▶ flash
driver/can (-DBLOB_CAN_FDCAN) ─────────┘
```

Same bare-metal pattern as [`h735_blinky`](../h735_blinky/): `Reset_Handler` calls
`main__main()` directly (no V `_vinit`), and with `-no-bounds-checking` the image
is **~1 KB with no heap** — the whole runtime path is board-init → open → recv →
send.

## Layout

| file | what |
|---|---|
| `main.v` | open bus 0 (FDCAN1), loop: `recv → echo back with id+1 → send` |
| `board.c` / `board.h` | FDCAN1 bring-up: HSE→kernel clock, APB clock, PH13/PH14 AF9 |
| `startup.c` | Cortex-M7 vector table + reset → `main__main()` |
| `linker.ld` | flash @ `0x08000000`, DTCM @ `0x20000000` (SRAMCAN is a fixed peripheral addr) |
| `Makefile` | transpile (`import driver.can` via `-path`) → cross-compile with the FDCAN backend |

The CAN core itself (init, bit timing, FIFOs, Tx/Rx) is in the shared
`driver/can/can_fdcan.c`; this example only provides the board glue it documents
needing: a kernel clock, the APB clock, and the pin mux.

## Board specifics (STM32H735G-DK)

- **CPU clock**: `board_clock_init()` brings the M7 to its full **550 MHz** (PLL1
  from HSE, 25÷5×220÷2). This needs VOS0, and VOS0 needs the core-supply mode set
  first — the DK is **Direct SMPS** (`PWR_CR3` `SMPSEN`, LDO off), so that's set
  before the VOS0 request or `VOSRDY` never asserts. ⚠️ The supply write must match
  the board's solder bridges (SB2/13/20/21 = SMPS); a mismatch **browns out VCORE
  and locks the debugger** — recover with `st-flash --connect-under-reset`. All the
  clock waits are bounded, so a rail that won't ready falls back to HSI 64 MHz
  rather than hang. FDCAN is untouched by this — its kernel clock stays HSE 25 MHz.
- **FDCAN1**: `PH13` = TX, `PH14` = RX, **AF9**, to the onboard 3.3 V CAN-FD
  transceiver. FDCAN1/2 are *not* behind the CAN solder bridges (only FDCAN3 is),
  so no board rework is needed.
- **Kernel clock**: HSE used directly (`FDCANSEL = HSE`). X1 is a **25 MHz
  oscillator (NZ2520SH), not a crystal**, so HSE runs in **bypass** (`HSEBYP`) —
  without that, `HSERDY` never sets and `open()` halts.
- **Bit timing**: 25 MHz / 500 kbit needs **10 tq/bit** (`NBRP 5`, tseg1 7 +
  tseg2 2 → 80 % sample). The `Makefile` passes `BLOB_FDCAN_KCLK_HZ=25000000`,
  `BLOB_FDCAN_TQ=10`, `BLOB_FDCAN_NTSEG1=7`, `BLOB_FDCAN_NTSEG2=2` so the driver's
  prescaler stays integer. Classic CAN only (the driver rejects an FD bus at open).

## Build & flash

```sh
make -C ../.. deps    # CMSIS headers into third_party/ (once)
make                  # build/canecho.bin
make flash            # st-flash write build/canecho.bin 0x08000000
```

## Wire it up & test

Connect FDCAN1's **CANH/CANL** (DK CN-side header) to a USB-CAN adapter
(PCAN / Kvaser / a second board), **500 kbit/s, classic**. CAN needs **120 Ω
termination at each end** — enable it on the adapter, and check the DK's CAN
termination (SB/jumper) so the bus isn't left unterminated.

From the host with the adapter up as `can0`:

```sh
candump can0 &                 # watch the bus
cansend can0 123#DEADBEEF      # send id 0x123, 4 bytes
#  -> board replies: 124#DEADBEEF   (id+1, same payload)
```

Every **odd-id** frame you send (id ≤ 0x7FF, ≤ 8 data bytes) comes back with its
id incremented; even ids are dropped by the parity filter (they're the reply
space — see above). **✅ Confirmed on hardware** (STM32H735G-DK ↔ PCAN-USB Pro FD,
500 kbit/s): `123`→`124`, `001`→`002`, ~0.7 ms round-trip, bus ACKed — that
sign-off run predates the parity filter and also probed `456`→`457`, which the
filter now ignores by design.
That's the on-silicon proof of the FDCAN driver — **`REQ-CAN-DRV-001/002/003`** (the
`h735-fdcan-hardware` sign-off in `requirements/verifications.toml`).

## If it's quiet

Flashed clean but no echoes? In likely order (this is the order that cracked it):

1. **CANH/CANL swapped** — the #1 culprit, and the one *this* board hit. A reversed
   pair still shows **both** lines swinging on a scope; only the polarity tells
   (correct: dominant = CANH↑ / CANL↓). Tell-tale: the board is out of INIT but its
   Rx FIFO stays empty (`RXF0S`=0, `PSR` `LEC`=7) and the adapter climbs to
   error-passive (nothing ACKs it). Swap them.
2. **Termination** — 120 Ω at **both** ends (the adapter, and the DK's CAN term
   jumper). No termination → no valid frames form.
3. **`open()` halted** (stuck in `main.v`'s `for {}`) → clock: confirm HSE bypass
   started (`HSERDY`). `make gdbserver` + `make gdb` stops at `main__main`; or
   `openocd` halt and read `FDCAN1->CCCR` (INIT still set?), `PSR`, `ECR`.
4. **Bitrate + a second ACKing node** — adapter at 500 k, **not** listen-only (a lone
   transmitter with no ACK goes error-passive). Watch for a *second* CAN channel
   silently ACKing and masking the real state — that faked us out for a while.

## Notes

- **Polled, no ISR.** `blob_can_recv` drains Rx FIFO0; the superloop polls it. No
  peripheral interrupts, so the vector table is all `Default_Handler`.
- **Warnings.** V's freestanding C emits benign 32-bit pointer-cast warnings from
  unused builtin paths; the link is clean and the CAN/board code compiles quietly.
- Verified to build a valid ~1 KB image (SP `0x20020000`, reset vector into flash,
  no heap). **✅ Confirmed on real hardware** — the id+1 round-trip above ran on an
  STM32H735G-DK against a PCAN-USB Pro FD.
