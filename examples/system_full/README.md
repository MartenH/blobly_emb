# `examples/system_full` — the reference system (4 ECUs + a CM4 satellite; CAN + Ethernet)

`system_full` is **the one reference system** for the blobly stack: a multi-node automotive system meant to exercise *every* shipped feature on real silicon, so the ~45 single-feature one-off examples can be retired. Every built node is a real **ThreadX** image — the CAN nodes are composed from a single [`system.toml`](system.toml), the Ethernet node is a self-contained SOME/IP endpoint, and the one exception is deliberate: the `tester` is a **declaration-only** node (nothing is built; blobly_net stands in for it).

It runs on **four boards** across **two CAN buses + Ethernet**:

- **`sysnode`** (STM32H735G-DK) — the **gateway**, routing signals `compute` ↔ `edge`; also a member of the `tel` SOME/IP segment (its `GwStatus` event) and its diagnostic server over **DoIP**, at `192.168.0.50` — declared in `system.toml`, not in the node.
- **`domain`** (NUCLEO-H755ZI-Q) — **dual-core** powertrain: a CM7 control loop + a **CM4 satellite** (`domain_m4`), with **NvM** persistence, cross-core **bulk** transfer, cross-core **CpuLoad**, a **two-core trace**, and a **CAN shell**.
- **`zone_a`** (NUCLEO-H723ZG) — the edge zone ECU: a node-local FB pipeline **and physical GPIO**.
- **`tcu`** (NUCLEO-H723ZG) — the telematics/connectivity node: **SOME/IP-over-Ethernet** (silicon-validated).

---

## Features exercised (the consolidation goal)

| Feature | Node(s) | Silicon status |
|---|---|---|
| 2-bus CAN gateway routing (raw copy + id remap) | `sysnode` | ✅ on-silicon |
| **Mixed classic↔CAN-FD backbone**: edge bus is CAN-FD (500k/2M), gateway forwards classic⇄FD | `sysnode` (H735 FDCAN2) + `zone_a` | ⏳ builds; **bench-pending** (PLL2 80 MHz FDCAN kernel + FD timing, #266) |
| NvM persistence (`DriveMode` survives resets) | `domain` | ✅ |
| Cross-core **bulk** + **CpuLoad** (AMP, CM7↔CM4) | `domain` + `domain_m4` | ✅ (bulkperf ~28 MB/s over CAN) |
| Two-core **trace** (thread/ISR/FB, one timeline) | `domain` | ✅ |
| CAN **shell** (`bulkperf`, `ps`, `bmc`) | `domain` | ✅ |
| Network Management (coordinated sleep/wake + NvM flush) | `compute` bus | ✅ |
| Node-local FB→FB signalling (intra-thread cell) | `zone_a` | ✅ |
| Physical **IO** (GPIO: button → signal, signal → LED) | `zone_a` | ⚙️ config-proven on silicon (re-flash after the #247 pool fix to see the LED) |
| Physical **PWM** (cross-node `LedLevel` → LD3 intensity, 0.5 Hz breathing) | `domain` → `zone_a` | ✅ on-silicon (TIM12 at 1 kHz, CCR1 sweeping 0..49999 over SWD, LD3 fades) |
| **Tester as a node**: `tester` (declaration only) produces `HostLedLevel` → `domain`'s LD3 as PWM; blobly_net restbus-simulates it | `tester` → `domain` | ✅ on-silicon via the CANsub (`simulation: tester`, H755 TIM12 CCR1 follows the sine) |
| **SOME/IP-over-Ethernet** (cyclic events + E2E + RPC rx) | `tcu` | ✅ silicon-validated (ping, tx/rx, E2E tx); the E2E receive path awaits a tcu bench run |
| **DoIP** (the UDS server over TCP/UDP 13400, one session with CAN) | `sysnode` | ✅ on-silicon (#338, hand-authored `[doip]`); declared in `system.toml` since rung 6 — ⏳ bench re-run pending |
| **DoIP entity transport** (routing-activation policy — the bench tester alone, `testers = [0x0E00]` — alive check, entity status, power mode, inactivity timers; docs/net.md) | `sysnode` | ⏳ builds; bench: `test/doip_entity.py` |
| A **gateway on the SOME/IP segment** (`GwStatus` to the bench, beside its CAN routes; one NetX for SOME/IP + DoIP) | `sysnode` | ⏳ builds; **bench-pending** |

---

## Nodes

| Node | Hardware | Role | Bus | In `system.toml`? |
|---|---|---|---|---|
| `sysnode` | STM32H735G-DK | Gateway: routes 4 signals `compute` ↔ `edge`; publishes `GwStatus` on `tel`; DoIP entity `0x07A0` at `192.168.0.50` | `compute` (can0/FDCAN1), `edge` (can1/FDCAN2), `tel` (Ethernet) | ✅ |
| `domain` | NUCLEO-H755ZI-Q (CM7) | Powertrain + persistence + AMP owner; NvM, bulk, trace, shell | `compute` (can0) | ✅ |
| `domain_m4` | …the H755's **CM4** | `domain`'s co-processor **satellite** (bulk producer + CpuLoad); a `[[partition]] image=`, flashed to flash **bank 2** (`0x08100000`) | — (built by `domain`'s gen) | — (a satellite, not a node) |
| `zone_a` | NUCLEO-H723ZG | Front zone: sensor→limiter FB pipeline + **physical GPIO + PWM** | `edge` (can1) | ✅ |
| `tcu` | NUCLEO-H723ZG | **Telematics/connectivity — SOME/IP-over-Ethernet** at `192.168.0.51` | `tel` (Ethernet) | ✅ |
| `tester` | — (nothing built) | **Declaration-only**: the bench tool as ONE node on BOTH buses — produces `HostLedLevel` on CAN, and is tcu's SOME/IP peer (`LampCmd`, `LampCmdSafe`) at `192.168.0.190` — and the receiver of sysnode's `GwStatus`; blobly_net restbus-simulates it | `compute` (can0), `tel` (Ethernet) | ✅ |

---

## The Ethernet node (`tcu`) — a member like any other

`tcu` publishes a cyclic, E2E-protected SOME/IP **telemetry event**, answers an RPC and a **command round trip**, and receives an **E2E-protected command** whose receive verdict (ok / timeout / integrity, and the frames the sequence showed missing) it reports back on `BenchSafeStatus` — all from config + the H723 Ethernet board driver (`boards/h723/eth.c`). It's **silicon-validated**: link + ARP + ICMP (`ping 192.168.0.51`, 0% loss), SOME/IP tx (service `0x0100`, event `0x8001`, E2E counter+CRC — validated with the pre-Profile-1 E2E format; the P01 wire awaits a bench run with the Ethernet connected) and rx (`uptime` RPC → response, request-id mirrored). Its wire shares `host_someip`'s service id `0x0100` and its `BenchTelem` / `BenchCmd` / `BenchCmdSafe` layouts, but is not identical: tcu's `BenchEcho` mirrors `BenchCmd` alone (host_someip's sums both levels), tcu adds `BenchSafeStatus` `0x8005`, and it has no `BenchEvent` / `BenchMixed`. The benches of the retired standalone `examples/h735_someip` moved here — the RPC to `nodes/tcu/bench_test.sh` (REQ-NET-016, check `tcu-someip-hwtest`) and the protected receive path to `test/tcu_e2e.lua` (REQ-E2E-002 on eth) — and both are **pending a tcu bench run**: they need the H723's Ethernet cabled to the LAN.

**Since #245 it is a full `system.toml` member, dissolved like every CAN node.** The segment is a `[bus.tel]` whose carrier is a SERVICE (`kind = "someip"`, a `service` + `version` where a CAN bus has its `dbc`), and — because there is no DBC to own the layout — the **events are declared by the system too**, as `[[frame]]`s carrying id, signal set, tx mode and E2E trailer. `tools/sysgen` lowers all of it into `gen-tcu.toml`, and `nodes/tcu/ecu.toml` is internals only: its target, its shell method binding, its partition and its FB.

Two things made that possible, and both are worth knowing:

- **A someip segment has no shared wire**, so the endpoint is the NODE's identity, not the bus's: each `[[node]]` carries `endpoint = { address, port }`, and each member's `peer` is *derived* from the other end of the events it exchanges — which is what makes reciprocity checkable rather than asserted. With sysnode on the segment it has three members, so each EVENT is the point-to-point unit: `tester` hears tcu and sysnode, and its generated config names `GwStatus`'s producer as that event's own `peer`.
- **The far end is declared as a node** — and it is the *same* node as the CAN-side tester. `tester` sits on `compute` **and** `tel`: it produces `HostLedLevel` on one and is tcu's peer at `192.168.0.190` on the other. That is what makes tcu's telemetry *received* by somebody under REQ-TOPO-001, instead of the model needing an "off-system" concept. One bench tool is one node: it was briefly two (`tel_bench` alongside `tester`) only because the lowering could not yet carry a CAN bus and a segment in one file.

  It is a **leaf on both, not a gateway.** Nothing routes between CAN and SOME/IP — that needs a translating bridge and is refused until its own rung. The distinction matters to the generator: a multi-bus node used to mean "router", which emits every bus in the CAN/DBC shape and no `[someip]` at all. `System.is_someip_leaf()` now owns the shape, because four places have to agree on it (two dissolution checks, the lowering, and the loom2v precheck — which silently skipped `tester` as a "gateway" the first time round, dropping the gate it used to have).

One model rule bends for the carrier, deliberately: a cross-node signal on a CAN bus carries **exactly one** value field, because a DBC signal *is* a scalar. A SOME/IP event's payload is a **struct** — its fields packed in canonical order — so `BenchTicks` carrying `{wraps, ticks}` is the ordinary case there, not an error.

The lowering is behaviour-preserving by construction: `tcu.bin` built from the system-lowered config is **byte-identical** to the image built when the wiring was authored in its own `ecu.toml`.

`sysnode` is a member of the segment too (ROADMAP rung 6): the gateway publishes its own `GwStatus` (uptime, from its one FB) there beside its CAN routes, and its `endpoint` is also where its DoIP server answers (`doip = { logical = 0x07A0 }` on its `[[node]]`) — so `nodes/sysnode/ecu.toml` authors none of its network. What is still a follow-up is the *deeper* half of #245: a signal crossing **eth↔CAN** needs a SOME/IP⇄CAN translating path on `sysnode`. Nothing crosses today — a route touching `tel` is refused — so that remains its own rung.

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

The CAN nodes link the generated comm thread against the shared `boards/common/comm_glue.c` — the one glue for every shape (one thread or several, one bus or a gateway's, io or none), listed by `gen/loom_build.mk` (`LOOM_GLUE_SRCS`); the network a node links — the board's eth driver, the NetX driver, the shared bring-up `driver/eth/netx_up.c` and the SOME/IP (`eth_netx.c`) and/or DoIP (`doip_netx.c`) seams its config asks for — is generated into `gen/loom_build.mk` (`LOOM_NET_SRCS`), plus `boards/common/iocb.c` for the eth node. All pass the `_vinit`-trap lint.

### The gateway on target

`sysnode`'s comm thread owns both FDCAN buses — it opens `can0` (FDCAN1 = compute) and `can1` (FDCAN2 = edge), arms each instance's Rx interrupt into one wake semaphore, and forwards the 4 resolved routes as a **raw payload copy + id remap**. This works because every route is *layout-identical*; a route whose layouts differ is rejected at gen time (host-only). The forwarded-frame count is the exported `g_fwd_count`, SWD-observable at the bench. Both buses are on the DK's own transceivers: FDCAN1 on `PH13`/`PH14`, FDCAN2 on `PB6`/`PB5` (AF9), clear of the Ethernet RMII pins.

### Bench notes

- **Flash** a node: `make -C nodes/<node> flash SERIAL=<st-link sn>` — every node takes the SAME selector, so the wrong board can't be written by using the wrong variable name. ST-Link serials → boards are in the bench notes.
- **Ethernet (`tcu`)**: on WSL, the board's UDP events land on the **Windows** side (mirrored networking), so validate SOME/IP with a `powershell.exe` listener, not a WSL socket. `ping` works from WSL because ICMP is shared. The RPC probe is `nodes/tcu/bench_test.sh` (`--flash` builds and writes tcu only given `BLOB_TCU_SERIAL`, so `make hwtest` never replaces zone_a on the bench H723 by accident; without it, it probes whatever answers at `192.168.0.51`). The E2E receive legs are `test/tcu_e2e.lua`, run through blobly_net's headless runner (`BLOBLY_NET=…; v -enable-globals -path "@vlib|@vmodules|$BLOBLY_NET/modules" run $BLOBLY_NET/cmd/script/run.v test/tcu_e2e.lua`). Both bind the tester's port 30491 and send first, since the Windows firewall drops an unsolicited inbound datagram until the host has sent to that endpoint.
- **Watch the CAN traffic**: [`system_full.blobnet`](system_full.blobnet) is a [blobly_net](https://github.com/MartenH/blobly_net) monitor for this bench — it taps both buses (`can0` = compute, `can1` = edge) and decodes them with the DBCs, so you can see the gateway forward. Run it from the blobly_net repo:
  `BLOBLY_PROJECT=/path/to/blobly_emb/examples/system_full/system_full.blobnet ./scripts/run_gui.sh`.
- **Diagnostics (UDS)**: every CAN node serves UDS over ISO-TP on the ids `system.toml` allocates — domain 0x7B0/0x7B8 and sysnode 0x7A0/0x7A8 on compute, zone_a 0x7C0/0x7C8 on edge (classic-sized ISO-TP on the CAN-FD bus), 0x7DF functional. `test/diag_domain.lua` runs against the watch project; `test/diag_nodes.lua` against [`test/diag_bench.blobnet`](test/diag_bench.blobnet), which transmits on edge too. After `st-flash --connect-under-reset`, clear the core-reset vector catch before an ECUReset test (the note in `diag_nodes.lua`), or 0x11 parks the node at its reset vector.
