# h735_canecho — CAN on hardware (STM32H735G-DK, FDCAN1)

The second bare-metal example: drive **real CAN frames** through the register-level
FDCAN driver (`driver/can/can_fdcan.c`, no HAL). The board opens FDCAN1 and echoes
every classic frame it receives back on the bus with **id + 1**, so a bench tool
sees a distinct reply for each frame it sends.

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

Every frame you send (id ≤ 0x7FF, ≤ 8 data bytes) comes back with its id
incremented. That round-trip is the on-hardware proof of the FDCAN driver —
it verifies **`REQ-CAN-DRV-001`** on real silicon.

## If it's quiet

Flashed clean but no echoes? In likely order:

1. **No bus traffic at all** → termination (both ends 120 Ω?) or CANH/CANL swapped.
2. **`open()` halted** (firmware stuck in `main.v`'s `for {}`) → clock: confirm HSE
   bypass started (`HSERDY`). `make gdbserver` + `make gdb` stops at `main__main`;
   step to `blob_can_open` and check its return, or `openocd` halt and read
   `FDCAN1->PSR`/`ECR` (bus-off / error counters) and `CCCR` (still in INIT?).
3. **TX but no echo** → the adapter's bitrate isn't 500 k, or it's not ACKing
   (a single node with no other ACKing device goes error-passive; the adapter
   counts as the second node, so keep it on the bus).

## Notes

- **Polled, no ISR.** `blob_can_recv` drains Rx FIFO0; the superloop polls it. No
  peripheral interrupts, so the vector table is all `Default_Handler`.
- **Warnings.** V's freestanding C emits benign 32-bit pointer-cast warnings from
  unused builtin paths; the link is clean and the CAN/board code compiles quietly.
- Verified to build a valid ~1 KB image (SP `0x20020000`, reset vector into flash,
  no heap). On-bus round-trip is the hardware confirmation step.
