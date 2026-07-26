# How do I add a signal?

A signal is a typed value flowing between two **endpoints**. An endpoint is a partition
or a bus — and that's all you say; the generator derives the transport from the topology:

| `from` → `to` | derived transport | you'll see in gen/ |
|---|---|---|
| same partition, same thread | struct cell in the thread state | `st.cell_<name> = outp...` |
| bus → partition | COM decode → IOC cell | `C.ioc_get(n, ...)` in the wrapper |
| partition → bus | IOC cell → cyclic tx in the comm loop | `C.ioc_pub(n, ...)` + a producer |
| satellite partition → bus/partition | **xioc slot** (cross-core) | `C.xcore_pub(slot, ...)` |

## 1. Declare it

```toml
[[signal]]
name   = "Workload"            # a valid identifier; becomes `sig.Workload`
fields = { v = "u32" }         # the APP-facing struct: field NAME = V type
from   = "app"                 # partition or bus name
to     = "can0"
```

Comments go ABOVE the block, never inside it (vlang/v#27684).

### What `fields` is (and isn't)

`fields` defines the **V struct your app code sees** — nothing about the wire. Field
names are yours to choose; each entry becomes a typed struct field in `sig/`:

```v
pub struct Workload {      // fields = { v = "u32" }
pub mut:
	v u32                  // handler code: outp.workload.v = ...
}
```

A signal with `fields = { n = "u32", acc = "u32" }` is a two-field struct
(`outp.m4_count.n`, `.acc`). Prefer a descriptive name over `v` (`speed_kph = "u16"`).
The name `valid` is reserved — a freshness flag some host transports carry.

The **wire layout is the DBC's job**, matched by NAME: when an endpoint is a bus, the
signal name must be a DBC signal, and the DBC says where its bits live. In DBC terms a
signal may start at any bit, span byte borders, and scale — the host bridge codec
handles that generally. The lean ThreadX target codec does NOT yet: it generates only
the trivial layout (unsigned little-endian u32 at bit 0, factor 1, offset 0) and
**fails generation loudly** for anything else — so a spanning signal can't silently
decode as garbage; it just doesn't build until the on-target DBC codec phase lands.
Practically: a bus-endpoint signal on target today is one u32 value field. Cross-core
(remote) signals are the exception where multiple fields hit the wire — one u32 lane
per field (up to 16 of `u32`/`u16`/`u8`/`bool`; 1–2 plain u32s without `valid` keep the
{a, b} pair cell), `DLC = 4 × lanes` with every lane SG-owned, checked. Past 2 lanes the
frame is FD-sized and waits for the FD comm owner — see
[move-data.md](move-data.md) for the full lane contract.

## 2. Wire it to an FB

The reader/writer is declared on the handler, and the generated `ports` structs grow a
field named after the signal:

```toml
[[fb.handler]]
name      = "on_100ms"
period_ms = 100
reads     = ["LoadCmd"]        # -> inp.load_cmd (sig.LoadCmd)
writes    = ["Workload"]       # -> outp.workload (sig.Workload)
```

In the app handler you just touch the port:

```v
pub fn (mut l LoadSlow) on_100ms(inp ports.LoadSlowIn, mut outp ports.LoadSlowOut) {
	outp.workload.v = burn(inp.load_cmd.iters)
}
```

`make gen` regenerates `sig/`, `ports/`, and the wrapper glue. Nothing else to write.

## Bus endpoints need the DBC

If `from` or `to` is a bus, the signal is on the wire: its **name must be a signal in
the example's `bus.dbc`**, which supplies the CAN id, DLC, and layout. Add the DBC
message first (see [add-a-frame.md](add-a-frame.md)).

The lean ThreadX target codec has rules (loom2v enforces them loudly):
- layout: plain unsigned little-endian 32-bit at bit 0, factor 1, offset 0,
- 11-bit id, DLC ≤ 8, one FB-read signal per rx message,
- a tx signal is written by exactly ONE FB (the IOC cell is single-writer),
- everything rides the one comm-thread bus (`[telemetry] bus`).

**What the DBC match covers.** The signal's **name, layout, and transmitter** are
enforced against the DBC: the name must be an `SG_`, the fields must match its
width/signedness/payload, and the `BO_` sender must be the producer. What is *not*
derived from the DBC is **who receives** it — the `SG_` receiver (RX) node list is
informational. Consumers come from which FBs `read` the signal, so in a multi-node
system the RX list need not equal the reader nodes; `syscheck` only checks that any
node the DBC names (`BO_` sender or `SG_` receiver) is a real `BU_` node — no
dangling references.

*Why not enforce it?* Who consumes a signal is a **node-local software fact** (an FB
read), and adding or dropping a reader is a node-internal change. If the RX list
were load-bearing, that internal edit would force a matching edit to the **shared,
system-owned DBC** — breaking "a node stays developable in isolation." Everything
that affects the wire or the wiring (layout, transmitter, a consumer with no
producer or on the wrong bus) is already checked, so the RX list would add
bookkeeping, not safety. See [system-from-nodes.md](system-from-nodes.md).

## Cross-core signals

Nothing new to learn: give `from` a partition that lives on another core (one declared
with `image =` or `external = true`) and the generator allocates an xioc slot — or, past
the {a, b} pair shape, a wide `xioc_n` channel — instead of an IOC cell. Constraints:
up to 16 fields of `u32`/`u16`/`u8`/`bool` (1–2 plain u32s without `valid` keep the
bench-verified pair cell); to a bus, `DLC = 4 × lanes` with the full lane contract of
[move-data.md](move-data.md), and 3+ lanes waits for the FD comm owner. `u64`, signed
ints, floats and >16 narrow fields are the pending #212 packing decision. See
[add-a-core.md](add-a-core.md) and [../multi-image.md](../multi-image.md).

```toml
[[signal]]
name   = "M4Count"             # DBC signal in M4LoadFrame
fields = { n = "u32", acc = "u32" }
from   = "m4"                  # satellite partition -> xioc slot, owner transmits
to     = "can0"
```

A cross-core signal `to = "<owner partition>"` gets a slot but no generated consumer —
that's for platform C readers (the `iocx` health check reads one this way).

## Verify

```sh
make gen && git diff sig/ ports/ gen/    # the new cell/slot/producer appears
make                                     # target build
candump can0 | grep <id>                 # bus signals: watch the PAYLOAD, not just the id
```
