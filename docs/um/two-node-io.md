# How do I wire a signal across two ECUs? (the button→lamp demo)

The smallest end-to-end blobly network: press a button on one node, an LED lights
on another. It exercises the whole stack — GPIO in → FB → CAN → FB → GPIO out —
across two independently-generated images on one bus, and every piece is config.
The system is [`examples/system_io`](../../examples/system_io): one `system.toml`
declares the shared frame and each node's `ecu.toml` is generated from it plus that
node's own io and FBs; nothing here is hand-written wiring. Design:
[../io.md](../io.md), [add-a-signal.md](add-a-signal.md),
[system-from-nodes.md](system-from-nodes.md).

## The two nodes

| | `system_io/nodes/h755` (tx) | `system_io/nodes/h735` (rx) |
|---|---|---|
| board | NUCLEO-H755ZI-Q | STM32H735G-DK |
| in | B1 user button `PC13` → `ButtonLamp` FB | `ButtonState` 0x310 → `RemoteLamp` FB |
| local out | LD1 green (mirrors the button) | LD `PC3`, **`active_low`** |
| bus | publishes `ButtonState` 0x310 (100 ms cyclic) | consumes it |

The shared contract is one CAN frame — **`ButtonState` / 0x310**, carrying
`BtnPressed` — declared once in `system.toml` (`body.dbc`). `examples/h755_io` is the
same tx node written as a complete `ecu.toml` with its own DBC; it talks to the
`h735` node unchanged, since the two meet only at the frame id. On the tx side the button is a signal
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
make -C examples/system_io        # gen-system, then both node images
```

Two ST-Links on the bench — flash each by serial (`st-info --probe` lists them):

```sh
make -C examples/system_io flash-h755 H755_SERIAL=<H755-serial>
make -C examples/system_io flash-h735 H735_SERIAL=<H735-serial>
```

Both transceivers on the **same CANH/CANL pair** as the PCAN adapter — three nodes,
one classic-500k bus (`ip link set can0 up type can bitrate 500000`). Watch it:

```sh
candump can0            # ButtonState 0x310 cyclic from the H755; CpuLoad 0x7E0 (H755) + 0x7E8 (H735)
cansend can0 310#01000000   # fake a press from the PC — the H735 lamp lights (rx half in isolation)
```

Then **press B1 on the H755**: its green LED and the H735's lamp both track the
button. First run on silicon as the hand-written pair (emb#150), then as
`system_io` with NM alive on 0x511/0x513 beside it.

## What this proves

- A signal crossing a bus is the same declaration as one crossing a thread — the
  generator derives the transport (IOC cell vs COM encode/decode vs a GPIO pad)
  from the endpoints ([add-a-signal.md](add-a-signal.md)); moving the LED from
  the tx to the rx node was a config change, not a rewrite.
- Board wiring (pad polarity, which LED, active-high vs -low) lives in the point
  declaration and the boards layer — never in the application signal.
- Two images built from two `ecu.toml`s interoperate on nothing but a shared
  frame id, exactly as a real vehicle bus does — the standalone `h755_io` and
  the generated `h735` node are such a pair.
