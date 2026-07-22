# h723_canecho — CAN echo on hardware (STM32H723, zone node)

Bare-metal CAN echo on the H723: opens **both** FDCAN1 and FDCAN2 and echoes every
received frame back with **id+2**, through the shared register-level driver
(`driver/can`, no HAL). The zone-node counterpart to
[`h735_canecho`](../h735_canecho/) (gateway, id+1) and [`h755_canfd`](../h755_canfd/).

The **id+2** reply is deliberate: when several canecho nodes share one bus, the
offset identifies which board answered (H735 → id+1, H723 → id+2).

## Board

The H723 is the same **H72x/H73x** family as the H735, but on a Nucleo-144 it uses
the H755's pin/clock arrangement — so the FDCAN bring-up matches `h755_canfd`:

| | TX | RX | AF |
|---|---|---|---|
| FDCAN1 | PD1 | PD0 | 9 |
| FDCAN2 | PB6 | PB12 | 9 |

Both pin sets are muxed, so a CAN-FD Click works in either socket. Kernel clock =
**HSE 8 MHz** (ST-LINK MCO, bypass) → 500 kbit at 16 tq (BRP 1), the driver default.
SYSCLK stays on the HSI reset default; the FDCAN kernel clock is independent of it,
so no PLL bring-up is needed.

## Build + flash

```sh
make                  # build/canecho.bin
st-flash --serial <stlink-serial> --reset write build/canecho.bin 0x08000000
```

## Test

Wire the transceiver to a USB-CAN adapter at **500 kbit/s classic**, 120 Ω at both
bus ends, then:

```sh
sudo ip link set can1 up type can bitrate 500000    # or: sudo blobly-can up
cansend can1 631#BB
candump can1        # -> 633 [1] BB   (id+2 = this node)
```

## Bring-up gotchas (all of these bit us on first light)

Every one of these produces "the node hears traffic but nothing works", so check
them in this order — and read the FDCAN registers over SWD, they tell you which:

1. **TXD wire (PD1 → transceiver TX).** If it's missing or swapped with RX, the node
   receives fine but cannot send the **ACK** bit — so it logs `LEC=5 (bit0 error)`,
   REC climbs to 127 → error-passive, the adapter never gets an ACK, and nothing
   echoes. `LEC=5` + `REC` climbing + `TEC=0` is the fingerprint of a dead TX line.
2. **Click VIO strap** — must be **3.3 V** for the STM32 logic side (a 5 V strap
   swings RXD 0–5 V into a 3.3 V pin and the bit decode falls apart).
3. **Termination** — measure CANH↔CANL with power off: **60 Ω** = two terminators
   (correct), 120 Ω = one, open = none. This rules out termination *and* polarity in
   one measurement, so do it before swapping CANH/CANL on a hunch.
4. **CANH/CANL orientation** — DB9 **pin 2 = CANL, pin 7 = CANH**.

### Reading the state over SWD

FDCAN1 is at `0x4000A000` (FDCAN2 at `0x4000A400`); `st-flash read` is *positional*:

```sh
st-flash --serial <s> read out.bin 0x4000A040 0x8   # ECR(0x40) + PSR(0x44)
```

- `CCCR` (0x18) `INIT=0` + `NBTP` (0x1C) programmed → `open()` ran, clock is good
- `PSR.LEC = 0` → communicating cleanly · `= 7` → no bus activity at all
- `ECR`: `TEC`/`REC` — REC climbing with TEC=0 means "receives but can't ACK"

Verified on silicon: clean echo, `TEC=0 / REC=0 / LEC=0`, bus ERROR-ACTIVE.
