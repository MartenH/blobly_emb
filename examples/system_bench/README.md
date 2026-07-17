# system_bench — the multi-node P1 system

The smallest real *system* of ECUs (docs/multi-node.md): the **H735-DK system
node** and the **H755 dual-core domain controller** on one shared bus
(`compute`), exchanging a signal and sharing an NM cluster. It exists to exercise
the **system-level validator** — the cross-node checks a single `ecu.toml`
cannot do because it cannot see its peers.

```
   sysnode (H735, nm 0x11)            domain (H755, nm 0x13)
   ├─ tx VehicleSpeed  ───────┐   ┌────────  rx VehicleSpeed
   └─ rx EngineRpm  ◄─────────┼───┼───────►  tx EngineRpm
                        compute bus (can0, 500 kbit)
```

## Run the checks

```sh
make syscheck                       # = tools/syscheck examples/system_bench/system.toml
# or point it anywhere:
make syscheck SYSTEM=path/to/system.toml
```

Clean output (every compute-bus signal has exactly one writer and one reader,
identities are unique, the cluster agrees):

```
system: 1 bus(es), 2 node(s), 0 route(s)
  bus compute: can0 500000 classic (compute.dbc)
  node sysnode: nm=0x11 trace=1 buses=['compute']
  node domain: nm=0x13 trace=2 buses=['compute']
syscheck: OK (0 warning(s))
```

## What is authored vs owned by the system

Each node keeps its **own `ecu.toml`** under `nodes/<name>/` — its partitions,
threads, and FBs (the logic). `system.toml` owns the **cross-node contract**: the
buses and their DBCs, and each node's **identities** (NM id, diagnostic address,
trace id). The validator cross-checks that the two agree (a node's `[nm] node`
must match the `nm` the system allocates it) and that the composition is sound.

## The checks (REQ-TOPO-*)

| Check | Requirement |
|---|---|
| One transmitter + at least one receiver per signal, per bus | REQ-TOPO-001 |
| One owner per CAN frame, per bus | REQ-TOPO-001 |
| Bus-scoped reachability (a consumer needs a producer on its bus or a route) | REQ-TOPO-001 |
| NM / alive / diagnostic / trace id uniqueness | REQ-TOPO-002 |
| Per-bus DBC conformance | REQ-TOPO-003 *(deferred — needs a DBC parse)* |
| NM cluster coherence — peers range + sleep/wake timing, alive-in-range | REQ-TOPO-004 |
| System↔node identity consistency; a bus a node claims maps to its ecu.toml | REQ-TOPO-005 |
| Route validity — gateway on both buses, distinct from/to, one of frame/signal | REQ-TOPO-006 |

## Next (docs/multi-node.md)

- **P1b** — *generate* each node's bus wiring from `system.toml` (the
  "dissolution": declare a cross-node signal once, emit the tx/rx into each
  node) rather than hand-authoring it on both sides.
- **P2** — add the **edge** bus (its own DBC) and an H723; the sysnode gateways
  `compute`↔`edge` with a frame route and a signal route.
