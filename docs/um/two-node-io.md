# How do I wire a signal across two ECUs? (the button→lamp demo)

The smallest end-to-end blobly network: press a button on one node, an LED lights
on another. It exercises the whole stack — GPIO in → FB → CAN → FB → GPIO out —
across two independently-generated images on one bus, and every piece is config.
Both example nodes are generated from their own `ecu.toml`; nothing here is
hand-written wiring. Design: [../io.md](../io.md), [add-a-signal.md](add-a-signal.md).

## The two nodes

| | `examples/h755_io` (tx) | `examples/h735_io_lamp` (rx) |
|---|---|---|
| board | NUCLEO-H755ZI-Q | STM32H735G-DK |
| in | B1 user button `PC13` → `ButtonLamp` FB | `ButtonState` 0x310 → `RemoteLamp` FB |
| local out | LD1 green (mirrors the button) | LD `PC3`, **`active_low`** |
| bus | publishes `ButtonState` 0x310 (100 ms cyclic) | consumes it |

The shared contract is one CAN frame — **`ButtonState` / 0x310**, carrying
`BtnPressed` — declared in each node's DBC. On the tx side the button is a signal
`from = "io"`; the `ButtonLamp` FB reads it, writes the green LED (`to = "io"`)
AND the bus frame. On the rx side `BtnPressed` arrives `from = "can0"`, the
`RemoteLamp` FB copies it to `LedRemote` (`to = "io"`). Neither app knows the
other exists — they meet at the frame id.

## The polarity gotcha (REQ-IO-017)

The H735G-DK's LED is wired **active-low** — the pad sinks the LED, so a low pad
lights it. Without saying so, `init = false` would drive the pad low and the lamp
would sit **lit at idle**, going dark on a press (found exactly this way on the
first cross-node run). Polarity is a property of the point, not the app:

```toml
[[io.gpio]]
name       = "LedRemote"
pin        = "PC3"
period_ms  = 10
init       = false
active_low = true   # logical true = pad LOW: the driver inverts at the boundary
```

Every value above the driver stays **logical** (`true` = asserted = lit); the
driver inverts on reads, writes, and the init level alike. The tx node's Nucleo
LEDs are active-high, so it declares nothing — the same signal, two wirings.

## Build, flash, run

```sh
make -C examples/h755_io          # tx
make -C examples/h735_io_lamp     # rx
```

Two ST-Links on the bench — flash each by serial (`st-info --probe` lists them):

```sh
st-flash --serial <H755-serial> write examples/h755_io/build/h755_io.bin 0x08000000
st-flash --serial <H735-serial> write examples/h735_io_lamp/build/h735_io_lamp.bin 0x08000000
st-flash --serial <each> reset
```

Both transceivers on the **same CANH/CANL pair** as the PCAN adapter — three nodes,
one classic-500k bus (`ip link set can0 up type can bitrate 500000`). Watch it:

```sh
candump can0            # ButtonState 0x310 cyclic from the H755; CpuLoad 0x7E0 (H755) + 0x7E8 (H735)
cansend can0 310#01000000   # fake a press from the PC — the H735 lamp lights (rx half in isolation)
```

Then **press B1 on the H755**: its green LED and the H735's lamp both track the
button. First silicon run of a blobly two-node network — user-verified on the
bench (emb#150).

## What this proves

- A signal crossing a bus is the same declaration as one crossing a thread — the
  generator derives the transport (IOC cell vs COM encode/decode vs a GPIO pad)
  from the endpoints ([add-a-signal.md](add-a-signal.md)); moving the LED from
  the tx to the rx node was a config change, not a rewrite.
- Board wiring (pad polarity, which LED, active-high vs -low) lives in the point
  declaration and the boards layer — never in the application signal.
- Two images built from two `ecu.toml`s interoperate on nothing but a shared
  frame id, exactly as a real vehicle bus does.
