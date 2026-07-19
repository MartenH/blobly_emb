# h755_io — the tx half of the two-node button→lamp demo

docs/io.md **P1** on the NUCLEO-H755ZI-Q (CM7). The three on-board points are
ordinary signals: **B1 user button (PC13)** in, **LD1 green (PB0)** and **LD2
yellow (PE1)** out. The `ButtonLamp` FB mirrors the button onto the green LED
**and** publishes it on the bus as **`ButtonState` / 0x310** (100 ms cyclic);
`Heartbeat` toggles the yellow LED every 500 ms so the output path is visible
with nothing pressed.

**This is one of a connected pair:**

- **tx (here):** button → `ButtonState` 0x310 → bus
- **rx: [`../h735_io_lamp`](../h735_io_lamp) —** 0x310 → a remote LED on an
  STM32H735G-DK

Press B1 and the green LED here *and* the remote lamp both light. Full recipe,
wiring, and the active-low polarity note:
[../../docs/um/two-node-io.md](../../docs/um/two-node-io.md).
