# `examples/system_full` — the reference system (4 ECUs + a CM4 satellite; CAN + Ethernet)

`system_full` is **the one reference system** for the blobly stack: a multi-node automotive system meant to exercise *every* shipped feature on real silicon, so the ~45 single-feature one-off examples can be retired. Every built node is a real **ThreadX** image — the CAN nodes are composed from a single [`system.toml`](system.toml), the Ethernet node is a self-contained SOME/IP endpoint, and the one exception is deliberate: the `tester` is a **declaration-only** node (nothing is built; blobly_net stands in for it).

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
| Physical **PWM** (cross-node `LedLevel` → LD3 intensity, 0.5 Hz breathing) | `domain` → `zone_a` | ✅ on-silicon (TIM12 at 1 kHz, CCR1 sweeping 0..49999 over SWD, LD3 fades) |
| **Tester as a node**: `tester` (declaration only) produces `HostLedLevel` → `domain`'s LD3 as PWM; blobly_net restbus-simulates it | `tester` → `domain` | ✅ on-silicon via the CANsub (`simulation: tester`, H755 TIM12 CCR1 follows the sine) |
| **SOME/IP-over-Ethernet** (cyclic events + E2E + RPC rx) | `tcu` | ✅ silicon-validated (ping, tx/rx, E2E) |

---

## Nodes

| Node | Hardware | Role | Bus | In `system.toml`? |
|---|---|---|---|---|
| `sysnode` | STM32H735G-DK | Gateway: routes 4 signals `compute` ↔ `edge` | `compute` (can0/FDCAN1), `edge` (can1/FDCAN2) | ✅ |
| `domain` | NUCLEO-H755ZI-Q (CM7) | Powertrain + persistence + AMP owner; NvM, bulk, trace, shell | `compute` (can0) | ✅ |
| `domain_m4` | …the H755's **CM4** | `domain`'s co-processor **satellite** (bulk producer + CpuLoad); a `[[partition]] image=`, flashed to flash **bank 2** (`0x08100000`) | — (built by `domain`'s gen) | — (a satellite, not a node) |
| `zone_a` | NUCLEO-H723ZG | Front zone: sensor→limiter FB pipeline + **physical GPIO + PWM** | `edge` (can1) | ✅ |
| `tcu` | NUCLEO-H723ZG | **Telematics/connectivity — SOME/IP-over-Ethernet** at `192.168.0.51` | `eth0` (Ethernet) | ❌ **see below** |
| `tester` | — (nothing built) | **Declaration-only**: the bench tool as a node, produces `HostLedLevel`; blobly_net restbus-simulates it | `compute` (can0) | ✅ |

---

## The Ethernet node (`tcu`) — and why it's *not* in `system.toml`

`tcu` publishes a cyclic, E2E-protected SOME/IP **telemetry event** and answers an RPC **command round trip**, all from config + the H723 Ethernet board driver (`boards/h723/eth.c`). It's **silicon-validated**: link + ARP + ICMP (`ping 192.168.0.51`, 0% loss), SOME/IP tx (service `0x0100`, event `0x8001`, E2E counter+CRC) and rx (`uptime` RPC → response, request-id mirrored). The wire is identical to `examples/h735_someip` / `host_someip`, so the same `blobly_net` oracle verifies it.

**But `tcu` is deliberately not a `[[node]]` in `system.toml` — and that's a real boundary, not an oversight.** The system model now *does* carry the Ethernet side: a `[bus.*]` declares its **carrier** (`kind = "someip"`, a `service` + `version` instead of a DBC), membership is **explicit** (a node names the bus, since each eth node has its own address), and `syscheck` validates the members' reciprocal peers, endpoint addresses, event ids and payload contracts. What blocks `tcu` is narrower and concrete:

**its peer is off-system.** The tcu talks to the **bench tool at `192.168.0.190`**, not to another ECU. REQ-TOPO-001 requires every transmitted signal to be received by ≥1 *node*, and a SOME/IP link is point-to-point. The CAN side answers this by making the tool a **node** (`tester`, below) that blobly_net simulates on the bench — the same could be done for the eth peer, but SOME/IP wiring is not lowered from `system.toml` yet (REQ-TOPO-003), so `tcu` joining is a follow-up. So `tcu`:

- **is** in the build — it's in the Makefile `NODES` list, so `make nodes` cross-builds it with the others; and
- **is not** in the cross-node *model* — its SOME/IP events aren't validated for writers/reachability the way the CAN signals are.

Until SOME/IP wiring is lowered from `system.toml`, the Ethernet node is a **build member, not a model member** — which is why you won't find it in `system.toml`.

### The tester is a node

Every real system has a tester on the bus, so `system_full` declares one: `tester` (`nodes/tester/ecu.toml` — a **declaration only**: one FB writing `HostLedLevel`, so the model's single-writer rule has its producer). Nothing is built for it: **blobly_net restbus-simulates it** (`simulation: tester` in the `.blobnet`, keyed on the DBC transmitter name — blobly_net reads `compute.dbc`, never the node) exactly as it would any absent ECU. Nothing in the model knows or cares that the node is "the tool" — no off-system concept, single-writer and reachability hold as for any node. It carries no `nm`: a tester is not an NM node.

*(The same is true of `domain_m4`: it's a CM4 **satellite image**, a `[[partition]] image=` inside `domain`'s own config, not a system-level node — so it isn't in `system.toml` either.)*

---

## Cross-node signals & gateway routes (the CAN system)

All four routes are **layout-identical** (same signal position/scale/DLC on both buses), so the gateway forwards each as a raw payload copy with an id remap — no decode/re-encode on target.

| Signal | Producer | Route (via `sysnode`) | Consumer | Frame ids | Rate |
|---|---|---|---|---|---|
| `VehicleSpeed` | `domain` (compute) | `compute` → `edge` | `zone_a` | `0x120` → `0x130` | 100 ms |
| `HeadlightCmd` | `domain` (compute) | `compute` → `edge` | `zone_a` | `0x123` → `0x131` | 100 ms |
| `LedLevel` | `domain` (compute) | `compute` → `edge` | `zone_a` | `0x126` → `0x133` | 100 ms |
| `HostLedLevel` | `tester` (compute; blobly_net on the bench) | — (consumed on `compute`) | `domain` | `0x127` | 100 ms |
| `SteeringAngle` | `zone_a` (edge) | `edge` → `compute` | `domain` | `0x132` → `0x125` | 50 ms |

This closes a **bidirectional** loop through the H735: `domain` switches its headlights on `zone_a`'s routed steering (`headlight_cmd = steering > 90`), and `zone_a` clamps its steering by the `VehicleSpeed` it receives from `domain`. Every cross-bus hop goes through the gateway's forwarder.

### Node-local signalling + physical IO (inside `zone_a`)

`zone_a` runs a **two-FB pipeline on one thread**: `SteerSensor` sweeps a raw angle onto a **node-local** signal `RawSteer` (`from == to` ⇒ an intra-thread cell, never on a bus, **not** in `system.toml`), and `SteerLimiter` reads it, clamps it by the received `VehicleSpeed`, and emits `SteeringAngle`.

`SteerLimiter` also drives **physical IO** (`docs/io.md`), tying the cross-node signals to real pins on the NUCLEO-H723ZG:

- the domain's **`HeadlightCmd`** (compute → gateway → here) lights **LD1 (PB0)** — a cross-node command reaching a physical pin;
- the domain's **`LedLevel`** (same path) — a 0.5 Hz triangle `PowertrainCtrl` breathes out (0..1000 permille) — is the duty of an **`[[io.pwm]]` point on LD3 (PB14, TIM12_CH1, 1 kHz)**, so the red LED visibly fades in and out. The DK's own LEDs (PC2/PC3) have no timer AF, which is why the fade lands on the Nucleo, not the gateway;
- the **user button (PC13)** forces a hard `SteeringAngle`, which rides back edge → gateway → compute — a physical input driving a cross-node signal.

The `[[io.gpio]]` / `[[io.pwm]]` points bind to `[[signal]]`s with `from/to = "io"`; the boards layer (`boards/h723`, generic `driver/io/io_stm32.c`) owns the pins — adding an IO point is config, not code.

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
| `nodes/zone_a/build/zone_a.bin` | `boards/h723` (H723ZG) | front-zone FBs + physical IO (GPIO + PWM) |
| `nodes/tcu/build/tcu.bin` | `boards/h723` (H723ZG) | SOME/IP-over-Ethernet |

The CAN nodes link the generated comm thread against the shared `boards/common/comm_glue.c` (or `io_glue.c` when the node also has IO); the eth node links `driver/eth/eth_netx.c` + `boards/common/iocb.c` + the H723 eth driver. All pass the `_vinit`-trap lint.

### The gateway on target

`sysnode`'s comm thread owns both FDCAN buses — it opens `can0` (FDCAN1 = compute) and `can1` (FDCAN2 = edge), arms each instance's Rx interrupt into one wake semaphore, and forwards the 4 resolved routes as a **raw payload copy + id remap**. This works because every route is *layout-identical*; a route whose layouts differ is rejected at gen time (host-only). The forwarded-frame count is the exported `g_fwd_count`, SWD-observable at the bench. Both buses are on the DK's own transceivers: FDCAN1 on `PH13`/`PH14`, FDCAN2 on `PB6`/`PB5` (AF9), clear of the Ethernet RMII pins.

### Bench notes

- **Flash** a node: `make -C nodes/<node> flash SERIAL=<st-link sn>` — every node takes the SAME selector, so the wrong board can't be written by using the wrong variable name. ST-Link serials → boards are in the bench notes.
- **Ethernet (`tcu`)**: on WSL, the board's UDP events land on the **Windows** side (mirrored networking), so validate SOME/IP with a `powershell.exe` listener, not a WSL socket. `ping` works from WSL because ICMP is shared. The tcu offers the same service (0x0100) as `examples/h735_someip`, so that example's probe verifies it at **its own address** — the script takes the target from `BLOB_SOMEIP_IP`:
  `BLOB_SOMEIP_IP=192.168.0.51 examples/h735_someip/bench_test.sh` (flash the tcu itself with `make -C nodes/tcu flash SERIAL=<sn>`; the script's `--flash` only builds its own H735 image).
- **Watch the CAN traffic**: [`system_full.blobnet`](system_full.blobnet) is a [blobly_net](https://github.com/MartenH/blobly_net) monitor for this bench — it taps both buses (`can0` = compute, `can1` = edge) and decodes them with the DBCs, so you can see the gateway forward. Run it from the blobly_net repo:
  `BLOBLY_PROJECT=/path/to/blobly_emb/examples/system_full/system_full.blobnet ./scripts/run_gui.sh`.
