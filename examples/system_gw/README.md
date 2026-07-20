# system_gw — the multi-node P2 gateway (signal routing)

The P2 successor to [system_bench](../system_bench) (P1, one bus): **two buses and
a gateway that routes a signal between them**. Design: [../../docs/multi-node.md](../../docs/multi-node.md)
(the "P2 — gateway generation" section).

```
 domain (H755)                sysnode (H735) = GATEWAY            zone (H723)
   produces                    compute <-> edge                   consumes
 VehicleSpeed  ── compute ──▶  decode VehSpeedFrame (compute.dbc)
                               re-encode VehSpeed_E (edge.dbc)  ── edge ──▶  VehicleSpeed
```

`VehicleSpeed` is produced by `domain` on the **compute** bus; `zone` consumes it
on the **edge** bus. The two buses carry their own DBCs (different frame ids and
rates), so the value only reaches `zone` because the gateway **signal-routes** it:
decode per `compute.dbc`, re-encode per `edge.dbc`.

## Generate + validate

```sh
make gen-system SYSTEM=examples/system_gw/system.toml   # sysgen -> gen-<node>.toml
make syscheck   SYSTEM=examples/system_gw/system.toml   # cross-node + route checks
```

`gen-sysnode.toml` (the gateway) gets **two** `[bus.*]` blocks (each with its DBC)
and the resolved route:

```toml
[[route]] # GENERATED — resolved interfaces + src/dst DBC frames
signal = "VehicleSpeed"
from = { bus = "can0", frame = "VehSpeedFrame" }
to   = { bus = "can1", frame = "VehSpeed_E" }
```

## What it proves (P2a: generation + validation)

- **Reachability trusts a signal route.** `zone` reads `VehicleSpeed` off the edge
  bus, which has no producer of its own — `syscheck` passes only because the route
  carries it. **Delete the `[[route]]` and `syscheck` fails** ("consumer reads it
  but is not on its bus … and no signal route carries it").
- **Single-writer, dest bus (REQ-TOPO-012).** The gateway is the sole on-wire
  writer of the routed value on edge; a second route or a local FB writing it is
  rejected.
- **No route cycles (REQ-TOPO-011).** A directed bus cycle for a routed signal is
  rejected before it can recirculate.

## What is still P2b/P2c (not here yet)

- The **runtime forwarder** (decode → dest-signal → the destination frame's COM
  producer, with validity/freshness + TX-mode) — loom2v generation.
- **Frame (raw-PDU) routing** with the full-contract compare (P2b).
- The **target multi-bus comm owner** (a channel + Rx ISR per bus, multiplexed
  into one thread) and the FDCAN1↔FDCAN2 bench (P2c). The nodes therefore skip
  the loom2v target gate for now (ecucheck still gates the schema).
