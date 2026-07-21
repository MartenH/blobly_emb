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

## Run the gateway on two vcans

The gateway node builds and runs on the host, straight from the dissolution — no
hand-wiring. It speaks a DBC per bus, so the build **merges** them (`tools/dbcmerge`)
into one that `dbc2cfg` + `loom2v` consume, then loom2v generates the
destination-producer forwarder from `gen-sysnode.toml` + the merged DBC:

```sh
sudo make vcan                                   # vcan0..vcan7 once
make -C examples/system_gw/nodes/sysnode         # sysgen -> merge -> codegen -> host build
examples/system_gw/nodes/sysnode/bin/app vcan0 vcan1
# inject the source frame on compute, watch the edge bus re-emit it:
cansend vcan0 120#E803000000000000               # VehSpeedFrame, VehicleSpeed = 1000
candump  vcan1                                    # -> 200 [8] E8 03 00 00 …  (VehSpeed_E, 200 ms)
```

Integration test (`nodes/sysnode/test/route_dissolution.lua`, 2 cases — value
preserved across the route + rate-adaptation to the edge's 200 ms cadence):

```sh
cd examples/system_gw/nodes/sysnode
BLOBLY_NET=$HOME/repos/blobly_net bash ../../../../scripts/integration-test.sh .
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

## What runs today (P2a, on host + vcan)

- **Generation + validation** (P2a.1): sysgen lowers the route; syscheck's
  reachability, single-writer, and no-cycle guards gate it.
- **The runtime forwarder** (P2a.2b): decode on the source bus → dest-signal →
  the destination frame's COM producer (transcode, validity/freshness, TX-mode,
  rate-adaptation) — loom2v-generated and proven on two vcans above.

## What is still P2b/P2c (not here yet)

- **Frame (raw-PDU) routing** with the full-contract compare (P2b).
- The **target multi-bus comm owner** (a channel + Rx ISR per bus, multiplexed
  into one thread) and the FDCAN1↔FDCAN2 bench (P2c). The nodes run on the host
  emitter for now (ecucheck still gates the schema); the loom2v target gate for
  a multi-bus node lands with P2c.
