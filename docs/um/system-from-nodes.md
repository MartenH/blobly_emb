# How do I compose a system? (system.toml vs ecu.toml)

Once you have more than one ECU, the cross-node contract — the bus, its DBC, the
NM cluster, and the signals that cross the wire — belongs to *the system*, not to
any one node. `system.toml` is where you declare it **once**; `tools/sysgen`
lowers it into a complete `gen-<node>.toml` per node by merging that system
contract with each node's authored internals. `two-node-io.md` shows the older
*manual* way (each node authors its own DBC and they meet at a frame id); this
page is the **dissolved** way, where nobody re-declares the shared contract.

Worked example: [`examples/system_io`](../../examples/system_io) — the same
button→lamp behaviour as the `h755_io` + `h735_io_lamp` pair, but the cross-node
signal is declared once. Design rationale: [../multi-node.md](../multi-node.md).

```sh
make gen-system SYSTEM=examples/system_io/system.toml   # sysgen -> gen-<node>.toml
make syscheck   SYSTEM=examples/system_io/system.toml   # cross-node checks
```

## Do I even need `system.toml`? (a single ECU doesn't)

No. A **single ECU** is a *complete* `ecu.toml` that declares its own signals —
`fields` and all — plus its buses and target, and builds with `loom2v` directly.
No `system.toml`, no `sysgen`:

```toml
# examples/h735_app/ecu.toml — a standalone node owns its whole contract
[[signal]]
name   = "LoadCmd"
fields = { iters = "u32" }
from   = "app"
to     = "app"
```
```sh
v run tools/loom2v examples/h735_app/ecu.toml examples/h735_app/bus.dbc …   # no system.toml
```

`system.toml` earns its keep only once **two ECUs share a signal**. Then that
signal's definition — `name`, `fields`, `cycle_ms` — is hoisted to `system.toml`
so the producer and every consumer agree on it **once**, and each node's
`ecu.toml` becomes *partial*: it authors only internals (partitions, FBs,
`reads`/`writes` by name) and never re-declares the shared signal.

| | single ECU (standalone) | multi-node system |
|---|---|---|
| `ecu.toml` | **complete** — owns its `[[signal]]` + `fields` | **partial** — internals only |
| `system.toml` | none | the shared `[[signal]]` contract |
| where a shared field name (`kph`) lives | in the `ecu.toml`, next to the code | in `system.toml` (it *is* shared) |
| build | `loom2v` on the `ecu.toml` | `sysgen` → `gen-<node>.toml` → `loom2v` |

So a field name only "lives at the system level" **because the signal is shared**:
the moment two ECUs must agree on a value, someone has to own its name, and the
dissolution puts that owner in `system.toml`. A node-local signal (io↔app, or
app↔its own partition) keeps its name right next to the FB code that uses it —
rename it and only that node's files move.

## Who owns what

| | authored in **`system.toml`** | authored in a node's **`ecu.toml`** | generated into **`gen-<node>.toml`** |
|---|---|---|---|
| buses (`interface`, `fd`, `bitrate`, `dbc`) | ✅ once, per bus | ✗ never | `[import] dbc` + `[bus.canX]` |
| NM cluster (`peers`, `timeout_ms`, `repeat_ms`) | ✅ on the bus | ✗ never | `[nm]` (per-node `node`/`alive` resolved) |
| **cross-node** signal (crosses the wire) | ✅ once (`producer`, `bus`, `frame`, `cycle_ms`) | ✗ never re-declare | `[[signal]]` with per-node direction + `[[frame]]` on the producer |
| node identities (`nm`, `diag`, `trace`) | ✅ on `[[node]]` | ✗ never | folded into `[nm]` / diag / trace ids |
| **node-local** signal (io↔app, app↔own partition) | ✗ | ✅ authored | copied through verbatim |
| io points (GPIO/ADC/PWM), FBs, threads, partitions | ✗ | ✅ authored | copied through verbatim |
| `[telemetry]`, `[target]` | ✗ | ✅ authored | copied through verbatim |

The rule of thumb: **if a peer node can observe it on the bus, it is the
system's; if it never leaves the node, it is the node's.**

## What goes in `system.toml`

The system file *composes* — it names the buses, the cross-node signals, and the
nodes. From [`examples/system_io/system.toml`](../../examples/system_io/system.toml):

```toml
[bus.body]
interface = "can0"
fd        = false
bitrate   = 500000
dbc       = "body.dbc"
nm        = { peers = [0x500, 0x53F], timeout_ms = 300, repeat_ms = 200 }

# the ONE cross-node signal, declared once: H755 -> bus -> H735
[[signal]]
name     = "BtnPressed"
fields   = { pressed = "u32" }
producer = "h755"          # which node transmits it (single writer)
bus      = "body"
frame    = "ButtonState"   # the DBC frame it rides in
cycle_ms = 100

[[node]]
name  = "h755"             # NUCLEO-H755ZI-Q — the button node
ecu   = "nodes/h755/ecu.toml"
buses = ["body"]
nm    = 0x11               # cluster-unique NM / diag / trace ids
diag  = { req = 0x7A0, rsp = 0x7A8 }
trace = 1

[[node]]
name  = "h735"             # STM32H735G-DK — the lamp node
ecu   = "nodes/h735/ecu.toml"
buses = ["body"]
nm    = 0x13
diag  = { req = 0x7B0, rsp = 0x7B8 }
trace = 2
```

You declare the signal and **who produces it** — not who consumes it. A consumer
is any node whose FB `reads` that signal name; sysgen wires the rx side and
`syscheck` proves there is exactly one producer and at least one consumer.

## What goes in a node's `ecu.toml`

Only the node's **application and its own board** — everything that is true of the
node in isolation, so it stays buildable and unit-testable on its own. It must
**not** name the bus, import the DBC, declare `[nm]`, or re-declare the cross-node
signal or its frame. From
[`nodes/h755/ecu.toml`](../../examples/system_io/nodes/h755/ecu.toml):

```toml
[[io.gpio]]                       # the node's own pins
name = "UserButton"
pin  = "PC13"
# ...

[[signal]]                        # NODE-LOCAL: both endpoints are io/app -> allowed
name   = "UserButton"
fields = { pressed = "bool" }
from   = "io"
to     = "app"

[[fb]]
name   = "ButtonLamp"
thread = "app_main"
  [[fb.handler]]
  name  = "on_10ms"
  reads = ["UserButton"]          # a node-local signal
  writes = ["LedGreen", "BtnPressed"]   # LedGreen is local; BtnPressed is the SYSTEM signal
```

Note the last line: an FB references a **system** signal (`BtnPressed`) by name in
its `reads`/`writes` just like a local one. That name is the whole coupling — the
node never says where it goes or what frame carries it. A `[[signal]]` block with
a **bus** endpoint (`to = "can0"`) is forbidden in a node ecu.toml: that would be
re-declaring the system contract, and `syscheck` rejects it. Local ones (both
endpoints `io` or the node's own partitions) are exactly what you author here.

## How they are merged (the lowering)

`make gen-system` runs `tools/sysgen`, which for each node emits a **system-owned
prologue** then appends the node's authored `ecu.toml` **verbatim**. The prologue
is derived entirely from `system.toml`. Here is the generated `gen-h755.toml`
(the **producer** — it is git-ignored, run `make gen-system` to regenerate it):

```toml
# GENERATED by tools/sysgen from system.toml — DO NOT EDIT.
[import]
dbc = "body.dbc"                  # <- from bus.body.dbc

[bus.can0]                        # <- from bus.body.interface
interface = "can0"
fd = false
core = 0

[nm]                              # <- node 0x11 + bus.body.nm
node  = 0x11
alive = 0x511                     #    derived: 0x500 | node
peers = [0x500, 0x53f]
timeout_ms = 300
repeat_ms = 200

[[signal]]                        # <- the cross-node signal, PRODUCER direction
name = "BtnPressed"
from = "app"                      #    app -> wire
to   = "can0"
  [[frame]]
  name = "ButtonState"           #    frame + cyclic tx emitted on the producer only
  tx   = { mode = "cyclic", cycle_ms = 100 }

# --- authored internals (ecu.toml) ---
# ... the node's ecu.toml, copied through unchanged ...
```

The **consumer** (`gen-h735.toml`) gets the mirror image of that one signal —
direction reversed, no frame:

```toml
[[signal]]
name = "BtnPressed"
from = "can0"                     # wire -> app
to   = "app"
```

So the single `system.toml` `[[signal]]` becomes a **tx** on the producer (with the
frame + cyclic timing) and an **rx** on every consumer — the direction resolved
per node from `producer =`. NM `node`/`alive` ids are resolved per node too
(`alive = 0x500 | node`), while `peers`/`timeout_ms`/`repeat_ms` come from the
bus. Everything below the `--- authored internals ---` marker is the node's
`ecu.toml` untouched.

From there each `gen-<node>.toml` is an ordinary node description: point its build
at it and the normal `make gen` (ecucheck + loom2v) runs per node exactly as for a
single-ECU example. `gen-<node>.toml` is generated — **never hand-edit it**;
change `system.toml` or the node's `ecu.toml` and regenerate.

## The checks `system.toml` unlocks (`make syscheck`)

Things a lone `ecu.toml` cannot see because it cannot see its peers:

- **Single writer per bus** — every cross-node signal has exactly one `producer`
  and at least one consumer; zero or two producers is a build error.
- **Reachability** — an FB that `reads` a system signal must have a producer on
  its bus (or a route, once gateways land — [../multi-node.md](../multi-node.md)).
- **Identity uniqueness** — no two nodes share an NM / diag / trace id.
- **No re-declared contract** — a node ecu.toml with a bus-endpoint `[[signal]]`,
  its own `[bus.*]`, or `[nm]` is rejected; those are the system's to own.

## What this buys you

The cross-node contract lives in one place, so it cannot drift: the two ends of
`BtnPressed` can't disagree on the frame id, the bit layout, or the direction,
because there is only one declaration. Each node still builds and unit-tests
alone from its `ecu.toml`. Moving a consumer to a different node, or adding a
third node, is an edit to `system.toml` — not a coordinated change across every
node's DBC.
