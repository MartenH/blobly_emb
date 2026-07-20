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

## Bench

Each generated node builds and flashes like any target example (the H755 with
`BOARD=h755zi`, the H735 with `BOARD=h735dk`), both on one CAN. Press B1 on the
H755 → the H735 LED follows; the H755's green LED mirrors locally and its yellow
blinks as a liveness beacon. (Per-node build wiring is the next increment; the
generation + cross-node validation above is what this example proves today.)
