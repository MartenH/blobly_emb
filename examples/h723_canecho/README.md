# h723_canecho — CAN echo on hardware (STM32H723, zone node)

Bare-metal CAN echo on the H723: opens **both** FDCAN1 and FDCAN2 and echoes every
received **request** frame back with **id + 0x102**, through the shared register-level
driver (`driver/can`, no HAL). The zone-node counterpart to
[`h735_canecho`](../h735_canecho/) (gateway) and [`h755_canfd`](../h755_canfd/).

**Why `+0x102`:** the `+0x100` lifts the reply *out of the request range* so a reply is
never itself echoed, and the `+2` identifies this node (`h735_canecho` replies `+1`).
Frames above the request range (std > `0x6FD`, ext > `0x1FFFFEFD`) are ignored, so a
reply can never overflow the identifier width and wrap to a low id.

> **One echo node per bus.** A node never receives its own frames, but two *mutually
> echoing* nodes on one bus ping-pong each other's replies forever. This example ignores
> reply-range ids, but `h735_canecho` currently echoes everything — so keep them on
> separate buses (the bench runs H735 on one PCAN channel, H723 on the other).

## Board

The H723 is the same **H72x/H73x** family as the H735, but on a Nucleo-144 it uses the
H755's pin/clock arrangement — so the FDCAN bring-up matches `h755_canfd`:

| | TX | RX | AF |
|---|---|---|---|
| FDCAN1 | PD1 | PD0 | 9 |
| FDCAN2 | PB6 | PB12 | 9 |

Both pin sets are muxed, so a CAN-FD Click works in either socket.

> **Jumpers are required — muxing the pins is not enough.** On the MikroE Click Shield
> the mikroBUS `TX/RX` sockets are wired to **USART** pins, *not* these FDCAN pins. Seat
> the **CAN FD 3 Click** (MIKROE-3992, TLE9251V) in a socket for power/ground/mounting,
> but take CAN from the Click's **edge RX/TX header**, jumpered to the FDCAN pins above —
> Click **RX → PD0**, Click **TX → PD1** (or PB12/PB6 for FDCAN2). Same wiring note as
> [`h755_canfd`](../h755_canfd/README.md). Also strap the Click's **STB → GND** and set
> its **VIO to 3.3 V**.

Kernel clock = **HSE 8 MHz** (ST-LINK MCO, bypass) → 500 kbit at 16 tq (BRP 1), the
driver default. SYSCLK stays on the HSI reset default; the FDCAN kernel clock is
independent of it, so no PLL bring-up is needed.

## Build + flash

```sh
make -C ../.. deps                       # CMSIS headers (gitignored; needed on a clean checkout)
make                                     # build/canecho.bin
st-info --probe                          # find this board's ST-LINK serial
make flash STLINK_SERIAL=0055...         # serial is REQUIRED: several probes are attached
```

The flash target refuses to run without `STLINK_SERIAL` — `st-flash` otherwise picks the
first probe it finds and would happily program a different board on the bench.

## Test

Wire the transceiver to a USB-CAN adapter at **500 kbit/s classic**, 120 Ω at both bus
ends, then:

```sh
sudo ip link set can1 up type can bitrate 500000    # or: sudo blobly-can up
cansend can1 631#BB
candump can1        # -> 733 [1] BB   (0x631 + 0x102)
```

Extended ids work the same way and the width is preserved: `18FF0100` → `18FF0202`.

## Bring-up gotchas (all of these bit us on first light)

Every one of these presents as "the node hears traffic but nothing works", so work
through them in this order — and read the FDCAN registers over SWD, which say *which*:

1. **TXD wire (PD1 → Click TX).** If it's missing, on the wrong pin, or swapped with RX,
   the node receives fine but cannot send the **ACK** bit — so it logs `LEC=5 (bit0
   error)`, REC climbs to 127 → error-passive, the adapter never gets an ACK, and nothing
   echoes. **`LEC=5` + REC climbing + `TEC=0` is the fingerprint of a dead TX line** —
   suspect it before touching CANH/CANL or termination. (This was our actual root cause:
   a jumper one pin off.)
2. **Click VIO strap** — must be **3.3 V** for the STM32 logic side; a 5 V strap swings
   RXD 0–5 V into a 3.3 V pin and the bit decode falls apart.
3. **Click STB → GND**, or the transceiver stays in standby and you see nothing at all.
4. **Termination** — measure CANH↔CANL with power off: **60 Ω** = two terminators,
   120 Ω = one, open = none. Note this checks **termination only** — resistance is
   unchanged by swapping the two conductors, so it says nothing about polarity.
5. **CANH/CANL orientation** — a separate check from (4): DB9 **pin 2 = CANL**,
   **pin 7 = CANH**. Reversed polarity shows up as form/stuff errors, not as a
   resistance change.

### Reading the state over SWD

FDCAN1 is at `0x4000A000` (FDCAN2 at `0x4000A400`); `st-flash read` is *positional*:

```sh
st-flash --serial <s> read out.bin 0x4000A040 0x8   # ECR(0x40) + PSR(0x44)
```

- `CCCR` (0x18) `INIT=0` + `NBTP` (0x1C) programmed → `open()` ran, clock is good
- `PSR.LEC = 0` → communicating cleanly · `= 7` → no bus activity at all · `= 5` → see (1)
- `PSR.BO = 1` → bus-off (TEC hit 256)
- `ECR`: `TEC`/`REC` — REC climbing with TEC=0 means "receives but cannot ACK"

Verified on silicon: clean classic + extended echo, 64-byte CAN-FD payload round-trip,
`TEC=0 / REC=0 / LEC=0`, bus ERROR-ACTIVE.

> **CAN-FD note:** 64-byte payloads are verified, but **BRS at 2 Mbit is not usable from
> the 8 MHz kernel clock** — it leaves only 4 time quanta in the data phase and the node
> goes bus-off (TEC→256). FD payloads were validated with BRS off. Running BRS needs a
> PLL-derived higher FDCAN kernel clock; the same limit applies to `h755_canfd`.
