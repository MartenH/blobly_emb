# `examples/system_full` — 3-ECU Multi-Node Automotive Benchmark (2 buses)

`system_full` is a multi-node automotive system composed from a single [`system.toml`](file:///home/mahi/repos/blobly_emb/examples/system_full/system.toml). Every node is a real **ThreadX** image generated from that one file. It runs on three boards across **two CAN buses**, with `sysnode` (the H735-DK) routing signals between them — both buses come out on the DK's own FDCAN transceivers, so `blobly_net` on the Linux host can tap both and watch the gateway work.

> Scope note: this is the deliberately-simple 2-bus starting point. A third bus (`body`) + a `zone_b` ECU, and the gateway's Ethernet/DoIP/SOME/IP edge, are later steps once the 2-bus loop is proven on silicon.

---

## Topology

```
              ┌───────────────────────── Linux host (blobly_net) ─────────────────────────┐
              │  taps BOTH buses (+ diag 0x7A0..0x7C8)                                     │
              └───────────────┬───────────────────────────────────────────┬───────────────┘
                              │ compute bus                                │ edge bus
                              ▼                                            ▼
        ┌─────────────────────────────┐        ┌───────────────────────────────────────────┐
        │      NUCLEO-H755ZI-Q         │        │              NUCLEO-H723ZG                 │
        │      domain (compute)        │        │               zone_a (edge)                │
        │  writes VehicleSpeed,        │        │  reads VehicleSpeed, HeadlightCmd;         │
        │  HeadlightCmd; reads         │        │  writes SteeringAngle                      │
        │  SteeringAngle               │        │                                            │
        └───────────────┬─────────────┘        └──────────────────────┬────────────────────┘
                        │ FDCAN1 = compute                             │ FDCAN2 = edge
                        ▼                                              ▼
              ┌──────────────────────────── STM32H735G-DK ────────────────────────────┐
              │  sysnode: ThreadX gateway. comm thread owns FDCAN1 + FDCAN2, forwards  │
              │  3 routes (raw copy + id remap). compute<->edge.                       │
              └───────────────────────────────────────────────────────────────────────┘
```

---

## Nodes & bus mapping

| Node | Hardware | Role | Bus | Diag ID | NM ID |
|---|---|---|---|---|---|
| `sysnode` | **STM32H735G-DK** | Gateway: routes 3 signals `compute` ↔ `edge` | `compute` (can0/FDCAN1), `edge` (can1/FDCAN2) | `0x7A0` / `0x7A8` | `0x11` |
| `domain` | **NUCLEO-H755ZI-Q** (CM7) | Powertrain: produces speed/headlight, reads steering | `compute` (can0) | `0x7B0` / `0x7B8` | `0x12` |
| `zone_a` | **NUCLEO-H723ZG** | Front zone: sensor→limiter FB pipeline over a node-local signal, produces steering | `edge` (can1) | `0x7C0` / `0x7C8` | `0x13` |

---

## Cross-node signals & gateway routes

All three routes are **layout-identical** (same signal position/scale/DLC on both buses), so the gateway forwards each as a raw payload copy with an id remap — no decode/re-encode on target.

| Signal | Producer | Route (via `sysnode`) | Consumer | Frame ids | Rate |
|---|---|---|---|---|---|
| `VehicleSpeed` | `domain` (compute) | `compute` → `edge` | `zone_a` | `0x120` → `0x130` | 100 ms |
| `HeadlightCmd` | `domain` (compute) | `compute` → `edge` | `zone_a` | `0x123` → `0x131` | 100 ms |
| `SteeringAngle` | `zone_a` (edge) | `edge` → `compute` | `domain` | `0x132` → `0x125` | 50 ms |

This closes a **bidirectional** loop through the H735: `domain` switches its headlights on
`zone_a`'s routed steering (`powertrain.v` — `headlight_cmd = steering > 90`), and `zone_a`
clamps its steering by the `VehicleSpeed` it receives from `domain` (`SteerLimiter`, below).
Every cross-bus hop goes through the gateway's forwarder — a routed input on one side changes
what the other side puts on the wire.

### Node-local signalling (inside zone_a)

Not everything crosses the wire. `zone_a` runs a **two-FB pipeline on one thread**: `SteerSensor`
sweeps a raw angle onto a **node-local** signal `RawSteer`, and `SteerLimiter` reads it, clamps
it to a speed-dependent maximum (using the `VehicleSpeed` it gets via the gateway), and emits
the result as `SteeringAngle`. `RawSteer` has `from == to` (both the `front` partition), so it
lowers to an intra-thread cell — it never touches a bus and is **not** in `system.toml`. This is
the "if it never leaves the node, it is the node's" rule (see
[`docs/um/system-from-nodes.md`](../../docs/um/system-from-nodes.md)) shown next to the cross-node routes.

---

## Build & Validation

```sh
cd examples/system_full

# 1. Validate cross-node invariants, single-writer rules, identity, and routing:
make syscheck

# 2. Dissolve system.toml into per-node gen-<node>.toml for all 3 nodes:
make gen

# 3. Cross-build the ThreadX images for ALL 3 nodes (needs arm-none-eabi + `make -C ../.. deps`):
make nodes           # -> nodes/{sysnode,domain,zone_a}/build/<node>.bin
```

### Node build status

**All three** nodes — including the gateway — cross-build to real ThreadX images from
`system.toml`:

| Node | Board | Image | Role |
|---|---|---|---|
| `sysnode` | `boards/h735dk` (H735 M7) | `nodes/sysnode/build/sysnode.bin` | 2-bus gateway |
| `domain` | `boards/h755zi` (H755 CM7) | `nodes/domain/build/domain.bin` | powertrain FBs |
| `zone_a` | `boards/h723` (H723ZG) | `nodes/zone_a/build/zone_a.bin` | front-zone FBs |

Each links the generated comm thread against the shared `boards/common/comm_glue.c` (IOC
pool, the FDCAN1/2/3 Rx ISRs, Loom-load telemetry) and `boards/common/trace_hooks.c`, and
passes the `_vinit`-trap lint.

**The gateway on target.** `sysnode`'s comm thread owns both FDCAN buses: it opens `can0`
(FDCAN1 = compute) and `can1` (FDCAN2 = edge), arms each instance's Rx interrupt into one
wake semaphore, and forwards the 3 resolved routes as a **raw payload copy + id remap**
(`if id==0x120 on can0 → send 0x130 on can1`). This works because every route is
*layout-identical* — the signal sits at the same bit position, scale, and DLC on both buses —
so no on-target decode/re-encode is needed (a route whose layouts differ is rejected at gen
time and stays host-only). The forwarded-frame count is the exported `g_fwd_count`,
SWD-observable at the bench.

**Silicon status.** Both buses are wired on `boards/h735dk`: FDCAN1 (compute) on `PH13`/`PH14`
and FDCAN2 (edge) on `PB6`/`PB5` (AF9) — the DK's two CAN-FD transceivers, clear of the
Ethernet RMII pins. Flash with `make -C nodes/sysnode flash` (add `SERIAL=<st-link sn>` to
pick a board when several ST-Links are attached).

**Watch the traffic.** [`system_full.blobnet`](system_full.blobnet) is a
[blobly_net](https://github.com/MartenH/blobly_net) monitor project for this bench — it listens
on both buses (SocketCAN `can0` = compute, `can1` = edge) and decodes them with the DBCs, so you
can see the gateway forward (the same value reappearing on the other bus under a new id). The
DBC paths inside it are relative to the `.blobnet` itself, so any checkout works — run it from
the blobly_net repo, pointing `BLOBLY_PROJECT` at your blobly_emb checkout:
`BLOBLY_PROJECT=/path/to/blobly_emb/examples/system_full/system_full.blobnet ./scripts/run_gui.sh`.
