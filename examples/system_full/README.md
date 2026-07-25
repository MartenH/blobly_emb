# `examples/system_full` — 4-ECU Multi-Node Automotive Benchmark

`system_full` is a comprehensive multi-node automotive system composed from a single [`system.toml`](file:///home/mahi/repos/blobly_emb/examples/system_full/system.toml). It exercises the full **blobly_emb** embedded stack across 4 hardware target nodes (H735-DK, H755 dual-core, and 2× H723 Nucleo boards) and the Linux host tester (`blobly_net`).

---

## Topology & Hardware Architecture

```
                  ┌─────────────────────────────────────────────────────────────┐
                  │                    Linux Host (blobly_net)                  │
                  └───────────────┬──────────────────────────────┬──────────────┘
                                  │ Ethernet                     │ CAN (diag)
                                  │ (DoIP / SOME-IP / TCP / UDP) │ (0x7A0-0x7C8)
                                  ▼                              ▼
                  ┌─────────────────────────────────────────────────────────────┐
                  │           STM32H735G-DK (sysnode: Central Gateway)         │
                  │  NetX Duo (ETH) + 3× FDCAN + SOME/IP Router + Bulk Gateway  │
                  └────────┬──────────────────────┬──────────────────────┬──────┘
                           │ FDCAN1 (compute)     │ FDCAN2 (edge)        │ FDCAN3 (body)
                           ▼                      ▼                      ▼
            ┌──────────────────────────┐  ┌──────────────────┐  ┌──────────────────┐
            │     NUCLEO-H755ZI-Q      │  │  NUCLEO-H723ZG   │  │  NUCLEO-H723ZG   │
            │     (domain ECU)         │  │   (zone_a ECU)   │  │   (zone_b ECU)   │
            │ CM7: Power / SecOC / E2E │  │ Front Actuators  │  │ Rear Body & HVAC │
            │ CM4: High-rate ADC / IOC │  │ Bulk Consumer    │  │ Bulk Streamer    │
            └──────────────────────────┘  └──────────────────┘  └──────────────────┘
```

---

## Target Nodes & Bus Mapping

| Node | Hardware Target | Role & Capabilities | Primary Bus(es) | Diagnostic ID | NM ID |
|---|---|---|---|---|---|
| `sysnode` | **STM32H735G-DK** | Central Gateway, NetX Duo DoIP & SOME/IP edge, multi-bus route encoder | `compute` (can0), `edge` (can1), `body` (can2) | `0x7A0` / `0x7A8` | `0x11` |
| `domain` | **NUCLEO-H755ZI-Q** | Dual-core (CM7+CM4 AMP) powertrain & vehicle dynamics, E2E & SecOC (AES-CMAC) | `compute` (can0) | `0x7B0` / `0x7B8` | `0x12` |
| `zone_a` | **NUCLEO-H723ZG (#1)** | Front Zone ECU (steering angle, headlight driver, PWM actuators, bulk consumer) | `edge` (can1) | `0x7C0` / `0x7C8` | `0x13` |
| `zone_b` | **NUCLEO-H723ZG (#2)** | Rear Body ECU (HVAC blower, tailgate status, ambient temp sensor, bulk log streamer) | `body` (can2) | `0x7D0` / `0x7D8` | `0x14` |

---

## Cross-Node Signals & Gateway Routes

| Signal | Producer | Source Bus | Gateway Routes | Consumer(s) | Rate |
|---|---|---|---|---|---|
| `VehicleSpeed` | `domain` | `compute` | `compute` → `edge` (sysnode) | `zone_a` | 100 ms |
| `EngineRpm` | `domain` | `compute` | `compute` → `body` (sysnode) | `zone_b` | 100 ms |
| `BrakeState` | `domain` | `compute` | `compute` → `body` (sysnode) | `zone_b` | 50 ms |
| `HeadlightCmd` | `domain` | `compute` | `compute` → `edge` (sysnode) | `zone_a` | 100 ms |
| `HVACCmd` | `domain` | `compute` | `compute` → `body` (sysnode) | `zone_b` | 200 ms |
| `SteeringAngle` | `zone_a` | `edge` | `edge` → `compute` (sysnode) | `domain` | 50 ms |
| `TailgateStatus` | `zone_b` | `body` | `body` → `compute` (sysnode) | `domain` | 200 ms |
| `AmbientTemp` | `zone_b` | `body` | `body` → `compute` (sysnode) | `domain` | 500 ms |

---

## Build & Validation

```sh
cd examples/system_full

# 1. Validate cross-node invariants, single-writer rules, identity, and routing:
make syscheck

# 2. Dissolve system.toml into per-node gen-<node>.toml for all 4 nodes:
make gen

# 3. Cross-build the ThreadX images for the 3 leaf nodes (needs arm-none-eabi + `make -C ../.. deps`):
make nodes           # -> nodes/{domain,zone_a,zone_b}/build/<node>.bin
```

### Node build status

The three **leaf** nodes cross-build to real ThreadX images from `system.toml`:

| Node | Board | Image |
|---|---|---|
| `domain` | `boards/h755zi` (H755 CM7) | `nodes/domain/build/domain.bin` |
| `zone_a` | `boards/h723` (H723ZG) | `nodes/zone_a/build/zone_a.bin` |
| `zone_b` | `boards/h723` (H723ZG) | `nodes/zone_b/build/zone_b.bin` |

Each links the generated comm thread + FBs against the shared `boards/common/comm_glue.c`
(the generic single-bus ThreadX comm glue: IOC pool, FDCAN1 Rx ISR, Loom-load telemetry)
and `boards/common/trace_hooks.c`, and passes the `_vinit`-trap lint.

`sysnode` is the **3-bus gateway**. It runs as a **host/sim** image today (`vcan0/1/2`) —
loom2v does not yet emit a multi-bus ThreadX comm owner (the "target multi-bus comm owner"
roadmap item: one comm thread owning three FDCAN channels + three Rx ISRs + on-target route
forwarding). Its routing is fully generated and exercised on vcan; the ThreadX gateway image
is the next rung.
