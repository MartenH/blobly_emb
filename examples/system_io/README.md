# system_io — the two-node IO demo, composed from one `system.toml`

The **button→lamp** demo you already know — press **B1 on the NUCLEO-H755ZI-Q**, an
LED follows on the **STM32H735G-DK** — but this time it is **one `system.toml`
that generates both nodes**, not two hand-written examples that duplicate the
cross-node contract. This is the P1b *dissolution* (docs/multi-node.md) applied to
a real, benchable IO system on the two boards on the desk.

## What is where

- **`system.toml`** declares the *one* cross-node signal — `BtnPressed`, carried by
  frame `ButtonState` (0x310), produced by `h755`, consumed by `h735` — plus the
  bus, the NM cluster, and each node's identities. Declared **once**.
- **`nodes/h755/`** and **`nodes/h735/`** author **only their internals**: each
  node's **local io** (the H755's button + two LEDs; the H735's lamp LED) and its
  FBs. The bus wiring, the frame, and `[nm]` are *generated*.

The interesting part: a node with GPIO has **node-local signals** (`UserButton`,
`LedGreen`, …) that are its *own*, distinct from the system's cross-node signal.
The dissolution now supports that — a node authors its local io while the system
owns the bus contract (REQ-TOPO-005).

## Generate + validate

```sh
make gen-system SYSTEM=examples/system_io/system.toml   # -> gen-h755.toml / gen-h735.toml
make syscheck   SYSTEM=examples/system_io/system.toml   # cross-node checks (single-writer, id, NM, DBC)
```

`gen-h755.toml` comes out as a complete ecu.toml: the generated `[bus.can0]`,
`[nm]`, `BtnPressed` `[[signal]]` + `ButtonState` `[[frame]]`, **followed by** the
authored `[io]`, the local io signals, and the `ButtonLamp` / `Heartbeat` FBs —
equivalent to the hand-written `h755_io`, but derived from the system.

## Build + flash both boards

```sh
make                                    # gen-system + build both node binaries
make flash-h755 H755_SERIAL=<st-link>   # NUCLEO-H755ZI-Q (button)
make flash-h735 H735_SERIAL=<st-link>   # STM32H735G-DK   (lamp)
```

Each node builds from its **generated** `gen-<node>.toml` through the same io+comm
ThreadX pipeline as `h755_io` / `h735_io_lamp`, parameterized by `BOARD`. Wire both
boards on one CAN bus, then **press B1 on the H755 → the H735 LED follows**; the
H755's green LED mirrors locally and its yellow blinks as a heartbeat.

Bench-verified: `can0` carries `ButtonState` 0x310 @100 ms, coherent NM alive ids
(0x511 h755, 0x513 h735), and both telemetry beacons — the whole two-node system
running on silicon, derived from one `system.toml`.
