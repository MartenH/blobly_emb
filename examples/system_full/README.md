# `examples/system_full` — the reference system (4 ECUs + a CM4 satellite; CAN + Ethernet)

`system_full` is **the one reference system** for the blobly stack: a multi-node automotive system meant to exercise *every* shipped feature on real silicon, so the ~45 single-feature one-off examples can be retired. Every node is a real **ThreadX** image — the CAN nodes are composed from a single [`system.toml`](system.toml), and the Ethernet node is a self-contained SOME/IP endpoint.

It runs on **four boards** across **two CAN buses + Ethernet**:

- **`sysnode`** (STM32H735G-DK) — the **gateway**, routing signals `compute` ↔ `edge`.
- **`domain`** (NUCLEO-H755ZI-Q) — **dual-core** powertrain: a CM7 control loop + a **CM4 satellite** (`domain_m4`), with **NvM** persistence, cross-core **bulk** transfer, cross-core **CpuLoad**, a **two-core trace**, and a **CAN shell**.
- **`zone_a`** (NUCLEO-H723ZG) — the edge zone ECU: a node-local FB pipeline **and physical GPIO**.
- **`tcu`** (NUCLEO-H723ZG) — the telematics/connectivity node: **SOME/IP-over-Ethernet** (silicon-validated).

---

## Features exercised (the consolidation goal)

| Feature | Node(s) | Silicon status |
|---|---|---|
| 2-bus CAN gateway routing (raw copy + id remap) | `sysnode` | ✅ on-silicon |
| NvM persistence (`DriveMode` survives resets) | `domain` | ✅ |
| Cross-core **bulk** + **CpuLoad** (AMP, CM7↔CM4) | `domain` + `domain_m4` | ✅ (bulkperf ~28 MB/s over CAN) |
| Two-core **trace** (thread/ISR/FB, one timeline) | `domain` | ✅ |
| CAN **shell** (`bulkperf`, `ps`, `bmc`) | `domain` | ✅ |
| Network Management (coordinated sleep/wake + NvM flush) | `compute` bus | ✅ |
| Node-local FB→FB signalling (intra-thread cell) | `zone_a` | ✅ |
| Physical **IO** (GPIO: button → signal, signal → LED) | `zone_a` | ⚙️ config-proven on silicon (re-flash after the #247 pool fix to see the LED) |
| **SOME/IP-over-Ethernet** (cyclic events + E2E + RPC rx) | `tcu` | ✅ silicon-validated (ping, tx/rx, E2E) |

---

## Nodes

| Node | Hardware | Role | Bus | In `system.toml`? |
|---|---|---|---|---|
| `sysnode` | STM32H735G-DK | Gateway: routes 3 signals `compute` ↔ `edge` | `compute` (can0/FDCAN1), `edge` (can1/FDCAN2) | ✅ |
| `domain` | NUCLEO-H755ZI-Q (CM7) | Powertrain + persistence + AMP owner; NvM, bulk, trace, shell | `compute` (can0) | ✅ |
| `domain_m4` | …the H755's **CM4** | `domain`'s co-processor **satellite** (bulk producer + CpuLoad); a `[[partition]] image=`, flashed to flash **bank 2** (`0x08100000`) | — (built by `domain`'s gen) | — (a satellite, not a node) |
| `zone_a` | NUCLEO-H723ZG | Front zone: sensor→limiter FB pipeline + **physical GPIO** | `edge` (can1) | ✅ |
| `tcu` | NUCLEO-H723ZG | **Telematics/connectivity — SOME/IP-over-Ethernet** at `192.168.0.51` | `eth0` (Ethernet) | ❌ **see below** |

---

## The Ethernet node (`tcu`) — and why it's *not* in `system.toml`

`tcu` publishes a cyclic, E2E-protected SOME/IP **telemetry event** and answers an RPC **command round trip**, all from config + the H723 Ethernet board driver (`boards/h723/eth.c`). It's **silicon-validated**: link + ARP + ICMP (`ping 192.168.0.51`, 0% loss), SOME/IP tx (service `0x0100`, event `0x8001`, E2E counter+CRC) and rx (`uptime` RPC → response, request-id mirrored). The wire is identical to `examples/h735_someip` / `host_someip`, so the same `blobly_net` oracle verifies it.

**But `tcu` is deliberately not a `[[node]]` in `system.toml` — and that's a real boundary, not an oversight.** The system model (`tools/sysmodel`) is **CAN-only**: every `[bus.*]` carries a **DBC** frame contract, and `syscheck` (REQ-TOPO-001) *rejects* a node that opens a bus the model doesn't declare. There is no eth/SOME-IP bus type in the model yet. So `tcu`:

- **is** in the build — it's in the Makefile `NODES` list, so `make nodes` cross-builds it with the others; and
- **is not** in the cross-node *model* — its SOME/IP services aren't validated for writers/reachability/contract the way the CAN signals are.

Teaching sysmodel to host an eth/SOME-IP bus (a `Bus.kind`, a SOME/IP service contract instead of a DBC, cross-network reachability) is tracked as **issue #245**. Until that lands, the Ethernet node is a **build member, not a model member** — which is why you won't find it in `system.toml`.

*(The same is true of `domain_m4`: it's a CM4 **satellite image**, a `[[partition]] image=` inside `domain`'s own config, not a system-level node — so it isn't in `system.toml` either.)*

---

## Cross-node signals & gateway routes (the CAN system)

All three routes are **layout-identical** (same signal position/scale/DLC on both buses), so the gateway forwards each as a raw payload copy with an id remap — no decode/re-encode on target.

| Signal | Producer | Route (via `sysnode`) | Consumer | Frame ids | Rate |
|---|---|---|---|---|---|
| `VehicleSpeed` | `domain` (compute) | `compute` → `edge` | `zone_a` | `0x120` → `0x130` | 100 ms |
| `HeadlightCmd` | `domain` (compute) | `compute` → `edge` | `zone_a` | `0x123` → `0x131` | 100 ms |
| `SteeringAngle` | `zone_a` (edge) | `edge` → `compute` | `domain` | `0x132` → `0x125` | 50 ms |

This closes a **bidirectional** loop through the H735: `domain` switches its headlights on `zone_a`'s routed steering (`headlight_cmd = steering > 90`), and `zone_a` clamps its steering by the `VehicleSpeed` it receives from `domain`. Every cross-bus hop goes through the gateway's forwarder.

### Node-local signalling + physical IO (inside `zone_a`)

`zone_a` runs a **two-FB pipeline on one thread**: `SteerSensor` sweeps a raw angle onto a **node-local** signal `RawSteer` (`from == to` ⇒ an intra-thread cell, never on a bus, **not** in `system.toml`), and `SteerLimiter` reads it, clamps it by the received `VehicleSpeed`, and emits `SteeringAngle`.

`SteerLimiter` also drives **physical IO** (`docs/io.md`), tying the cross-node signals to real pins on the NUCLEO-H723ZG:

- the domain's **`HeadlightCmd`** (compute → gateway → here) lights **LD1 (PB0)** — a cross-node command reaching a physical pin;
- the **user button (PC13)** forces a hard `SteeringAngle`, which rides back edge → gateway → compute — a physical input driving a cross-node signal.

The `[[io.gpio]]` points bind to `[[signal]]`s with `from/to = "io"`; the boards layer (`boards/h723`, generic `driver/io/io_stm32.c`) owns the pins — adding an IO point is config, not code.

---

## Build

```sh
cd examples/system_full

make syscheck   # validate cross-node invariants, single-writer rules, identity, routing (CAN model)
make gen        # dissolve system.toml into per-node gen-<node>.toml
make nodes      # cross-build ALL node images + the CM4 satellite (needs arm-none-eabi + `make -C ../.. deps`)
```

`make nodes` builds every `NODES` image **and** the `domain_m4` satellite (after `domain`, whose gen emits it):

| Image | Board | What it is |
|---|---|---|
| `nodes/sysnode/build/sysnode.bin` | `boards/h735dk` (H735 M7) | 2-bus gateway |
| `nodes/domain/build/domain.bin` | `boards/h755zi` (H755 CM7) | powertrain + NvM + bulk + trace + shell |
| `nodes/domain_m4/build/domain_m4.bin` | `boards/h755zi` (H755 **CM4**) | the satellite (bulk producer + CpuLoad), flashed to bank 2 (`0x08100000`) |
| `nodes/zone_a/build/zone_a.bin` | `boards/h723` (H723ZG) | front-zone FBs + physical IO |
| `nodes/tcu/build/tcu.bin` | `boards/h723` (H723ZG) | SOME/IP-over-Ethernet |

The CAN nodes link the generated comm thread against the shared `boards/common/comm_glue.c` (or `io_glue.c` when the node also has IO); the eth node links `driver/eth/eth_netx.c` + `boards/common/iocb.c` + the H723 eth driver. All pass the `_vinit`-trap lint.

### The gateway on target

`sysnode`'s comm thread owns both FDCAN buses — it opens `can0` (FDCAN1 = compute) and `can1` (FDCAN2 = edge), arms each instance's Rx interrupt into one wake semaphore, and forwards the 3 resolved routes as a **raw payload copy + id remap**. This works because every route is *layout-identical*; a route whose layouts differ is rejected at gen time (host-only). The forwarded-frame count is the exported `g_fwd_count`, SWD-observable at the bench. Both buses are on the DK's own transceivers: FDCAN1 on `PH13`/`PH14`, FDCAN2 on `PB6`/`PB5` (AF9), clear of the Ethernet RMII pins.

### Bench notes

- **Flash** a node: `make -C nodes/<node> flash SERIAL=<st-link sn>` (or `H723=<sn>` for the H723 nodes). ST-Link serials → boards are in the bench notes.
- **Ethernet (`tcu`)**: on WSL, the board's UDP events land on the **Windows** side (mirrored networking), so validate SOME/IP with a `powershell.exe` listener (see `examples/h735_someip/bench_test.sh`), not a WSL socket. `ping` works from WSL because ICMP is shared.
- **Watch the CAN traffic**: [`system_full.blobnet`](system_full.blobnet) is a [blobly_net](https://github.com/MartenH/blobly_net) monitor for this bench — it taps both buses (`can0` = compute, `can1` = edge) and decodes them with the DBCs, so you can see the gateway forward. Run it from the blobly_net repo:
  `BLOBLY_PROJECT=/path/to/blobly_emb/examples/system_full/system_full.blobnet ./scripts/run_gui.sh`.
