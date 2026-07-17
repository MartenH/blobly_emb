# system_bench — the multi-node P1 system

The smallest real *system* of ECUs (docs/multi-node.md): the **H735-DK system
node** and the **H755 dual-core domain controller** on one shared bus
(`compute`), exchanging a signal and sharing an NM cluster.

```
   sysnode (H735, nm 0x11)            domain (H755, nm 0x13)
   ├─ tx VehicleSpeed  ───────┐   ┌────────  rx VehicleSpeed
   └─ rx EngineRpm  ◄─────────┼───┼───────►  tx EngineRpm
                        compute bus (can0, 500 kbit)
```

## The dissolution model (P1b)

A cross-node signal is authored **once**, in `system.toml`, with its producer and
DBC frame:

```toml
[[signal]]
name     = "VehicleSpeed"
fields   = { kph = "u16" }
producer = "sysnode"
bus      = "compute"
frame    = "VehSpeedFrame"   # authored in compute.dbc
```

Each node's `ecu.toml` under `nodes/<name>/` carries **only its internals** — a
partition/thread and FBs that `read`/`write` those signals by name. No `[bus]`,
no `[[signal]]` bus lines, no `[[frame]]`, no `[nm]`: those are **generated**.

```toml
# nodes/sysnode/ecu.toml  (authored — internals only)
[[fb.handler]]
name   = "on_100ms"
reads  = ["EngineRpm"]      # a cross-node signal
writes = ["VehicleSpeed"]   # a cross-node signal
```

## Generate + check

```sh
make gen-system     # sysgen -> gen-<node>.toml per node, each gated by ecucheck
make syscheck       # cross-node checks (single-writer, identity, NM, routes)
```

`make gen-system` merges `system.toml` + each node's internals into a **complete**
`gen-<node>.toml` (derived `[bus]`/`[[signal]]`/`[[frame]]` wiring + a generated
`[nm]` identity, `alive = peers.lo + node`), then runs the real `ecucheck` on the
result — so a generated node is guaranteed buildable by `loom2v`. The DBC is never
touched (it's the authored wire contract). `make syscheck` auto-detects the
dissolution model from the presence of system-scope `[[signal]]`s.

## What is authored vs generated

| | authored | generated |
|---|---|---|
| **system.toml** | buses (+ DBC, NM cluster), cross-node signals (+ producer/frame), node identities | — |
| **node ecu.toml** | partitions/threads/FBs + read/write intent | — |
| **compute.dbc** | frame ids + bit layout (the wire contract) | — |
| **gen-<node>.toml** | — | `[bus]` + `[[signal]]` tx/rx + `[[frame]]` + `[nm]`, then the authored internals |

## The checks (REQ-TOPO-*)

| Check | Requirement |
|---|---|
| One producer per signal, on its bus, whose FB writes it | REQ-TOPO-001/005 |
| One owner per DBC frame | REQ-TOPO-001 |
| Every read/written signal is reachable (a producer, or a route) | REQ-TOPO-001 |
| NM / diagnostic / trace id uniqueness | REQ-TOPO-002 |
| Per-bus DBC conformance — frame exists, DBC transmitter = producer, fields fit | REQ-TOPO-003 |
| NM cluster is system-declared (peers + timing), coherent by construction | REQ-TOPO-004 |
| Identities system-allocated; a claimed bus maps to the node | REQ-TOPO-005 |
| Route validity — gateway on both buses, distinct from/to, one of frame/signal | REQ-TOPO-006 |

## Next (docs/multi-node.md)

- **P2** — add the **edge** bus (its own DBC) and an H723; the sysnode gateways
  `compute`↔`edge` with a frame route and a signal route.
