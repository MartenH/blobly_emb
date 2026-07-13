# How do I add a signal?

A signal is a typed value flowing between two **endpoints**. An endpoint is a partition
or a bus — and that's all you say; the generator derives the transport from the topology:

| `from` → `to` | derived transport | you'll see in gen/ |
|---|---|---|
| same partition, same thread | struct cell in the thread state | `st.cell_<name> = outp...` |
| bus → partition | COM decode → IOC cell | `C.ioc_get(n, ...)` in the wrapper |
| partition → bus | IOC cell → cyclic tx in the comm loop | `C.ioc_pub(n, ...)` + a producer |
| satellite partition → bus/partition | **xioc slot** (cross-core) | `C.duo_pub(slot, ...)` |

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
signals are the exception where two fields hit the wire ({a, b} at bytes 0–3/4–7,
DLC = 4 × field count, checked).

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

## Cross-core signals

Nothing new to learn: give `from` a partition that lives on another core (one declared
with `image =` or `external = true`) and the generator allocates an xioc slot instead of
an IOC cell. Constraints: 1–2 `u32` fields, no `valid` field, and if it goes to a bus the
DBC DLC must be 4 × field count. See [add-a-core.md](add-a-core.md) and
[../multi-image.md](../multi-image.md).

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
