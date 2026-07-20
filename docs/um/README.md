# User manual — how do I ...?

Task-oriented guides for working on a blobly ECU. Each page is a recipe against a real
example (usually `examples/h755_threadx`, the two-core reference); the design rationale
lives in the sibling `docs/*.md` files and is linked, not repeated.

| I want to... | page |
|---|---|
| add a signal (FB→FB, FB→CAN, CAN→FB, cross-core) | [add-a-signal.md](add-a-signal.md) |
| add a CAN frame / change tx timing | [add-a-frame.md](add-a-frame.md) |
| add a function block (component + handler) | [add-an-fb.md](add-an-fb.md) |
| add a thread or partition | [add-a-thread.md](add-a-thread.md) |
| add another core (a satellite image) | [add-a-core.md](add-a-core.md) |
| add a shell command | [add-a-shell-command.md](add-a-shell-command.md) |
| record and view a trace | [record-a-trace.md](record-a-trace.md) |
| build, flash, and talk to the target (bench, bootloader, blobly_net GUI) | [build-and-flash.md](build-and-flash.md) |
| wire a signal across two ECUs (the button→lamp demo) | [two-node-io.md](two-node-io.md) |
| compose a system from nodes (system.toml vs ecu.toml, how they merge) | [system-from-nodes.md](system-from-nodes.md) |
| bring up a new board | [../porting.md](../porting.md) (design doc; boards/ layer) |

## The mental model (10 lines)

- One **`ecu.toml` per example** describes the whole ECU node: buses, partitions/threads,
  FBs, signals, frames, and the platform modules (telemetry, trace, shell, NM).
- `make gen` (in the example dir) runs **ecucheck** (schema gate) then **loom2v**, which
  generates everything mechanical: `sig/` (signal types), `ports/` (per-FB In/Out),
  `gen/loom_gen.v` (threads, scheduling, wrappers, the comm loop), the trace manifest,
  and — for multi-core nodes — the satellite core's image too.
- **You write app code only**: an `app/` struct per FB with one method per handler, pure
  V, no-alloc, reading `In` ports and writing `Out` ports. Everything else is config.
- Signal **transports are derived, never configured**: same thread → struct cell; other
  thread, same core → IOC cell; bus endpoint → COM encode/decode; another core → xioc
  slot ([../multi-image.md](../multi-image.md)).
- Generated files are **committed** and never hand-edited; regenerate instead.

## The edit → verify loop

```sh
vim ecu.toml            # or app/*.v
make gen                # ecucheck + loom2v (fails loudly on config errors)
make                    # freestanding build (target examples)
git diff gen/ sig/ ports/   # review what the config change actually did
```

Repo gates before a PR: `make check` (ecucheck on every example), `make lint`
(no-alloc), `make trace-check` (requirements ledger), `v test comm/ tools/`.

## One trap to know about

**Never put a `#` comment inside a `[[...]]` table block** — V's TOML parser silently
drops the key after the comment (vlang/v#27684). ecucheck rejects it, but write comments
*above* the block from the start. See the note at the top of any example ecu.toml.
