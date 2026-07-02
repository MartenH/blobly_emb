# h755_canfd — two-bus CAN on hardware (STM32H755, Nucleo-H755ZI-Q)

Bare-metal **two-bus** CAN echo on the dual-core H755: **FDCAN1** and **FDCAN2**,
each echoing received classic frames back with **id+1**, through the shared
register-level driver (`driver/can`, no HAL). The H755 counterpart to
[`h735_canecho`](../h735_canecho/) (which is single-bus on the H735).

```
main.v ──V -freestanding──▶ canfd.c ─┐
board.c (clock+pins) ─────────────────┼─ arm-none-eabi-gcc ─▶ canfd.elf ─▶ .bin ─▶ flash
driver/can (-DBLOB_CAN_FDCAN) ────────┘
```

## Pins (Nucleo-H755ZI-Q + MikroE Click Shield for Nucleo-144)

| bus | TX | RX | AF | Morpho |
|---|---|---|---|---|
| **FDCAN1** | `PD1` | `PD0` | 9 | CN11-55 / CN11-57 |
| **FDCAN2** | `PB6` | `PB12` | 9 | CN12-odd-17 / CN12-even-16 |

The shield's mikroBUS `TX/RX` sockets are wired to **USART** pins, not FDCAN — so
seat two **CAN FD 3 Clicks** (MIKROE-3992, TLE9251V transceivers) in sockets 1 & 3
for **power/ground + mounting**, but take CAN from each click's **edge RX/TX
header**, jumpered to the FDCAN pins above. (Confirm `PB6` isn't claimed by a
socket UART in CubeMX; if it is, use `PB13` for FDCAN2 TX — needs its solder bridge.)

## Clock

Kernel clock = **HSE**. On this board HSE is an **8 MHz clock from the ST-LINK MCO
in bypass mode** (default SB config), so `board.c` sets `HSEBYP`. 8 MHz / 500 kbit
= exactly **16 tq (BRP 1)** = the driver's default → **no bit-timing override**
(unlike the H735's 25 MHz). If your board has the 25 MHz X3 crystal fitted, drop
`HSEBYP` and pass `BLOB_FDCAN_KCLK_HZ=25000000` + the tseg override.

## Build & flash

```sh
make -C ../.. deps    # CMSIS headers (once)
make                  # build/canfd.bin
make flash            # st-flash write build/canfd.bin 0x08000000
```

Dual-core note: this builds for the **M7** (`-DCORE_CM7`) and flashes to
`0x08000000`. The M4 is left idle; deciding which core owns which FDCAN is the AMP
step (the IOC region is the cross-core seam — see `docs/multicore-perf.md`).

> **Toolchain:** needs a V with the freestanding amd64-asm fix (vlang **#27564**,
> on master). Stock `0.5.1` emits x86 `syscall` asm that arm-gcc rejects — if you
> hit `impossible constraint in 'asm'` in `builtin__sys_call*`, update V
> (`cd ~/v && git checkout master && git pull && make`).

## Test

Wire each bus's CANH/CANL to a USB-CAN adapter (500 kbit/s classic, 120 Ω both
ends). `cansend`/`candump` on each: a frame in → the same payload back with id+1.
That round-trip on both buses verifies **FDCAN1 + FDCAN2 on real silicon** and is
the first exercise of the H755's dual FDCAN.
