# h735_io_lamp — the rx half of the two-node button→lamp demo

docs/io.md **P1** on the STM32H735G-DK. It consumes **`ButtonState` / 0x310**
off the bus (`BtnPressed`), and the `RemoteLamp` FB drives a local LED on **PC3**
to match. The DK's LED is wired **active-low**, so the point declares
`active_low = true` — logical `true` (pressed) lights it; without that flag it
would sit lit at idle (found on the first cross-node run, REQ-IO-017).

**This is one of a connected pair:**

- **tx: [`../h755_io`](../h755_io) —** a NUCLEO-H755ZI-Q button → `ButtonState`
  0x310
- **rx (here):** 0x310 → the PC3 lamp

The two images are generated independently and meet only at frame id 0x310.
Full recipe + wiring: [../../docs/um/two-node-io.md](../../docs/um/two-node-io.md).
