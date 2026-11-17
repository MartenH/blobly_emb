# blobly_emb

**An automotive ECU stack in [V](https://vlang.io), configured from `ecu.toml` and the bus DBC.**
You write the application as Function Blocks: small structs with private state, whose handlers turn
typed input ports into output ports. The configuration does the rest: it generates the COM codec,
the scheduling and the cross-core transport, and configures and wires the stack's UDS server, fault
memory, NvM, network management, DoIP, SOME/IP and bootloader. All of it is static code with no
heap.

It is sim-first. A node runs as a Linux program on `vcan`, and the same model builds for STM32H7
on ThreadX, or bare metal for a single-core node: a node's `[target]` table picks which. It is
verified by hand on three STM32H7 boards (H723, H735, H755), and tested over the bus with its
companion tester, [Blobly Net](https://github.com/MartenH/blobly_net). MIT licensed.

![ecu.toml and the DBC feed the generators (loom2v and the rest), which produce one node's code: Function Blocks scheduled by the Loom, the COM codec, diagnostics, NvM and network management. That code runs on Linux vcan as a simulation, or on an STM32H7 with ThreadX, and Blobly Net tests it over CAN and DoIP.](docs/overview.drawio.svg)

## Why blobly_emb

- **Application code with no stack API.** An FB never calls `send()`, `nvm_write()` or
  `set_dtc()`. Sending on CAN, persisting a value, driving a pin and reporting a fault are port
  fields plus a few lines of config.
- **Configuration is text.** A node is one `ecu.toml` plus its bus DBC; a system adds one
  `system.toml`, which owns the buses and the cross-node signals. Every key is in a schema, so
  your editor completes and validates it, and generation is a `git diff` you can review.
- **Transport follows placement.** A signal names only who writes it and who reads it. The
  generator picks a local cell, a lock-free buffer, a cross-core slot or a CAN frame. Moving an FB
  to the other core is its `thread` line, or generation says why it cannot move yet.
- **The whole system is checked at build time.** One writer per signal per bus, reachability
  through gateways, route cycles, NM clusters and unique diagnostic ids, across every node.
- **No heap, checked on the binary.** CI fails every STM32 image it builds in which an allocator
  symbol survives the link, and every allocation the compiler reports in generated host code.
- **Unsafe configurations do not build.** A state-changing service reachable over DoIP without a
  security level, a start value outside the signal's range, a journal that would wear out the
  flash before `min_years`: generation stops and says why.
- **Simulate first, then flash.** COM, diagnostics, gateways, E2E and the bootloader session all
  run on a PC, driven by an open tester that reads the same DBC.
- **Traceability in the repo.** 337 requirements as TOML, tests that declare what they verify,
  bench runs recorded per board, and a traceability report CI regenerates and checks.

## Instead of AUTOSAR Classic

blobly_emb keeps the AUTOSAR communication semantics that earn their keep and drops the
middleware around them. The pattern-by-pattern comparison is
[docs/autosar-comparison.md](docs/autosar-comparison.md).

| | AUTOSAR Classic (MICROSAR, tresos) | blobly_emb |
|---|---|---|
| Configuration | ARXML and a BSW configurator | `ecu.toml` + DBC, schema-checked text |
| Application interface | `Rte_Read`, `Rte_Write`, `Dem_SetEventStatus`, NvM calls | fields of the FB's generated `In` and `Out` structs |
| Input coherence | implicit S/R snapshot per runnable | inputs snapshotted before each handler, outputs published after |
| Cross-core data | OS-Application partitioning, OS IOC, per-core RTE config | an ordinary `[[signal]]`; one image per core from one config |
| Fault memory | DEM, called by the application | a test result on an FB `Out` port, debounced; 0x19/0x14/0x85 served |
| Variant coding | NvM blocks behind DCM | `[[param]]`: a read-only `In` field, coded with 0x2E (ThreadX targets) |
| Licence | commercial | MIT |

Skipped on purpose: client-server calls, exclusive areas, multiple instantiation and XCP.
Planned: queued (every-occurrence) signals, handlers triggered on reception, and mode management.

## Quick start

Everything here runs on a Linux PC (or WSL2) with no hardware. You need the V compiler CI uses,
at the commit in [`.v-version`](.v-version) (V3, built from source; Blobly Net pins the same
commit, and its `scripts/setup_env.sh` installs it), and `can-utils` to watch the bus.

```sh
make vcan                                # bring up vcan0..vcan7 (needs sudo)
cd examples/overspeed && make all        # generate from ecu.toml + bus.dbc, build bin/app
./bin/app vcan0 &                        # the ECU, as a Linux process
candump vcan0,110:7FF &                  # LampFrame: byte 0 is WarnLamp, bytes 1-2 its E2E CRC and counter
cangen vcan0 -g 10 -I 100 -L 8 -D 0000DC0500000000   # VehicleSpeed 150 km/h every 10 ms -> 110 [3] 01 ..
```

Stop `cangen` and the lamp goes off after the 200 ms receive deadline: the speed signal's status
turns to `timeout` and the FB treats it as no speed. Stop the app and `candump` too
(`kill $(jobs -p)`) before the next step, which starts its own copy of the app.

**Drive it with the tester.** From the example's folder:

```sh
git clone https://github.com/MartenH/blobly_net ~/blobly_net
make test BLOBLY_NET=$HOME/blobly_net    # runs the app on vcan0 and every test/*.lua against it
```

That runs overspeed's nine Lua suites: the lamp logic, the receive deadline, UDS, routines, IO
control, fault memory, E2E, SecOC, and a simulated brake ECU sending corrupt and frozen frames.
The tester encodes signals from the same `bus.dbc`; [scripts/integration-test.sh](scripts/integration-test.sh)
is the harness.

Each example builds from its own folder (`make all`; `make list` from the root lists them). The
host examples need only V; the STM32 ones (`h735_*`, `h755_*`, `system_full`, `system_io`, ...) cross-build and
also need `arm-none-eabi-gcc` and `make deps`. Good places to start:

| example | what it shows |
|---|---|
| [`minimal`](examples/minimal/) | one FB between two CAN signals |
| [`overspeed`](examples/overspeed/) | six FBs on two cores, every signal path, UDS, faults, E2E and SecOC |
| [`gateway`](examples/gateway/), [`gw_signal`](examples/gw_signal/) | frame routes and signal routes between two buses |
| [`io_gpio`](examples/io_gpio/) | a button and an LED as signals; on the host the pins are files |
| [`boot_sim`](examples/boot_sim/) | the bootloader's programming session on `vcan`, backed by a file |
| [`system_full`](examples/system_full/) | the reference system: four boards, two CAN buses and Ethernet, from one `system.toml` (cross build; on a PC, `make syscheck` checks it) |

## An FB in ten lines

From [`examples/overspeed`](examples/overspeed/). The FB:

```v
pub struct OverspeedDetector {
pub mut:
	active bool
}

pub fn (mut fb OverspeedDetector) on_10ms(inp ports.OverspeedDetectorIn, mut out ports.OverspeedDetectorOut) {
	fb.active = inp.filtered_speed.status == .ok && inp.filtered_speed.kph > 120
	out.overspeed = sig.Overspeed{
		active: fb.active
	}
}
```

Its part of `ecu.toml`:

```toml
[[signal]]
name = "FilteredSpeed"
fields = { kph = "u16", status = "RxStatus" }
from = "sense"
to   = "sense" # local (same core)

[[signal]]
name = "Overspeed"
fields = { active = "bool" }
from = "sense"
to   = "ctrl"
transport = "double" # across cores

[[fb]]
name      = "OverspeedDetector"
thread    = "sense_main"
  [[fb.handler]]
  name      = "on_10ms"
  period_ms = 10
  reads     = ["FilteredSpeed"]
  writes    = ["Overspeed"]
```

`sense` runs on core 0 and `ctrl` on core 1, so `FilteredSpeed` becomes a plain struct cell and
`Overspeed` a lock-free inter-core channel. The FB code is the same either way. The generator
writes the port structs:

```v
pub struct OverspeedDetectorOut {
pub mut:
	// signal "Overspeed" — ch, transport double, sense -> ctrl
	overspeed sig.Overspeed
}
```

and a [`signal-map.md`](examples/overspeed/signal-map.md) that follows each signal from the FB
that writes it to its readers and, for a bus signal, to its DBC frame, bits and scaling. In this example 347 lines of `ecu.toml`, 156 lines of FBs and a
25-line `main.v` generate 2,319 lines of V.

## What it does

### Application model and generation

- **Function Blocks**: private state plus periodic handlers taking `(inp, mut out)`; the `In` and
  `Out` structs are generated from `ecu.toml`.
- **The Loom**: one static scheduler per thread, firing on a fixed grid so jitter never adds up
  to drift; after an overrun it resyncs instead of bursting. Per-handler timing and per-core load
  are measured.
- **One `make gen`**: `dbc2cfg` (DBC codec), `ecucheck` (schema gate), `cfg2v` (channel tables),
  `loom2v` (ports, threads, COM, diagnostics, NvM, NM, DoIP, SOME/IP, IO, trace, per-core images)
  and `sigmap` (the signal map). Each example's generated code is committed, and CI checks that
  it is fresh (a system's per-node output is regenerated, not committed).
- **One schema** for `ecu.toml` and `system.toml`: validation with "did you mean" hints, a
  generated [config reference](docs/config-reference.md), and JSON Schemas your editor uses.
- **Systems of ECUs**: `system.toml` declares buses, nodes, their identities, cross-node signals
  and routes; `make gen-system` produces each node's full config and `syscheck` checks the whole.
- **Generated gateways**: frame routes (forward unchanged, optional id remap, firewall allow-list)
  and, on the host bridge, signal routes (decode, rescale, re-encode, rate-adapt, re-protect with
  E2E or SecOC).

### Multicore and RTOS

- **Three kinds of target** (`[target] kind`): a Linux process, a bare-metal superloop for a
  single-core node, or ThreadX with generated threads, stacks and priorities.
- **AMP, one image per core**: a satellite core's image is generated from the owner's
  `ecu.toml`, with one shared slot map both images compile against.
- **Wait-free cross-core slots**: plain stores and barriers, no LDREX/STREX and no retry loop.
  On the H755 bench: 0 torn reads in 1 million.
- **Images that disagree are detected**: a hash of the whole cross-core map and a per-boot nonce
  make a stale or mismatched core read as silent, never as cross-talk.
- **Satellite FBs** read bus signals with their status, exchange signals both ways, write
  persisted signals, read coded parameters and own faults.
- **Cross-core bulk transfer**: a zero-copy block ring with an interrupt doorbell, about 33 MB/s
  measured on the H755 bench.
- **Selectable buffering** per signal on the host: seqlock, double or triple buffer.

### Communication

- **DBC codec**: Intel and Motorola, signed, factor and offset, value tables; FBs see physical
  units. A sent value is held to the DBC range and counted, never wrapped into the bits.
- **Initial payloads** from `GenSigStartValue`, so a frame sent before its FB has run is valid.
- **Transmission modes**: cyclic, on change with a minimum gap, mixed, and triggered.
- **Receive monitoring**: a deadline per frame, counted from start, and a per-signal status
  (`never_received`, `ok`, `timeout`, `integrity`) that can raise a DTC with no FB code.
- **AUTOSAR E2E Profile 1**, pinned to vectors from an independent implementation; the contract
  can come from DBC attributes shared with Blobly Net.
- **SecOC-style authentication** with AES-128 CMAC and a freshness counter, combinable with E2E.
- **CAN network management**: a CanNm-shaped state machine with partial networking; the bus goes
  quiet in sleep and the NvM flush runs at prepare-bus-sleep.
- **CAN and CAN-FD**: a register-level STM32H7 FDCAN driver (no HAL; BRS, 64-byte frames,
  29-bit ids, bus-off and overrun counts) and SocketCAN on Linux.
- **Ethernet** on NetX Duo from static packet pools: UDP, **SOME/IP** events and a served method,
  and a **DoIP** entity over TCP.

### Diagnostics and the bootloader

- **ISO-TP** on CAN and CAN-FD: messages up to 4095 bytes, 11- or 29-bit ids, normal fixed
  addressing, frames up to 64 bytes.
- **UDS server**: 0x10, 0x11, 0x14, 0x19, 0x22, 0x27, 0x29, 0x28, 0x2E, 0x2F, 0x31, 0x3E and
  0x85, NRCs in ISO 14229-1 order, and a per-node service table setting each service's sessions
  and security level.
- **0x27** with lockout counts kept in NvM, so a reset buys no extra guesses; **0x29**
  authentication with Ed25519 keys as the alternative.
- **Fault memory**: debounce, enable conditions, the ISO status byte (seven bits maintained;
  warningIndicatorRequested is never set), aging, snapshots and extended data; on a ThreadX
  target it is persisted so that a power cut at any point restores a coherent memory.
- **Variant coding** (`[[param]]`), **routines** run by an FB with 0x78 meanwhile, and **IO
  control** applied where the signal is published, never inside an FB.
- **DoIP gateway**: a DoIP node routes a tester's requests to CAN nodes behind it, once the tester
  has unlocked the gateway. On the bench: routed reads in 1.4-1.7 ms, and a node reprogrammed
  through the gateway in 3.0 s.
- **Bootloader** per node, built from its config: a UDS programming session, images signed with
  Ed25519 (in-tree, no vendor crypto) and checked before the valid mark is written, so a torn
  update leaves the ECU in the bootloader, never bricked. The application hands off with 0x10 02.

### Storage

- **NvM journal**: CRC'd records appended over a flash sector pair; after a power cut mid-write or
  mid-compaction it mounts with the last complete value of each block.
- **Persistence by config**: mark a signal `persist = "now"` or `"shutdown"`. Stored on ThreadX
  targets; a host build warns and keeps it in RAM.
- **Wear proven per build**: the generator computes worst-case writes per hour for every journal
  writer and refuses a configuration that cannot last `[nvm] min_years`.

### Trace and observability

- **On-board trace over CAN, no debug probe**: thread switches on the M7 and M4 ports, the ISRs
  that bracket themselves, every FB dispatch and IO service, in a per-core ring dumped over
  ISO-TP; an owner and a satellite core on one timeline with a measured clock offset, drawn by
  Blobly Net.
- **Load telemetry**: per-core load over 100 ms, 1 s and 10 s, broadcast as CAN frames.
- **CAN shell**: `ps`, `stat`, `bmc`, and project commands of one `ecu.toml` entry and a C function.
- **IO as signals**: ADC, GPIO and PWM bound to ordinary signals; host builds back them with files.
- **LVGL display** on the STM32H735G-DK's touch LCD.

### Boards

| board | core | verified on the bench |
|---|---|---|
| NUCLEO-H755ZI-Q | Cortex-M7 400 MHz + Cortex-M4 | FDCAN (classic frames), dual-core AMP, ThreadX, UDS, NvM, GPIO, trace |
| STM32H735G-DK | Cortex-M7 550 MHz | CAN-FD, Ethernet, UDP/TCP, DoIP and DoIP routing, SOME/IP, NM, display |
| NUCLEO-H723ZG | Cortex-M7 400 MHz | CAN-FD, ThreadX, UDS, fault memory with a power cut, field update |

The Nucleo boards need an external CAN transceiver. Porting to another RTOS or CAN stack means one
CAN backend and one OS backend; a new board adds a board package (clocks, pins, linker scripts)
([docs/porting.md](docs/porting.md)). ThreadX, NetX Duo and CMSIS are fetched at pinned
commits by `make deps`.

## Works with Blobly Net

[**Blobly Net**](https://github.com/MartenH/blobly_net) is the tester and simulation side: an
open bus tester for CAN, CAN-FD, LIN, DoIP and SOME/IP, written in V. It is how this repo's
integration tests run.

- Its headless Lua runner drives the examples that have `test/*.lua` suites on `vcan`
  (`make test`) and the boards on the bench, encoding signals from the same DBC.
- It stands in for the ECUs a system declares but does not build: a simulated server answers
  diagnostics as `system.toml` and the node's `ecu.toml` describe it.
- It flashes through the bootloader and draws the multi-core trace.
- The wire formats the two share are pinned by golden vectors on both sides: E2E Profile 1, the
  0x29 Ed25519 exchange, ISO-TP CAN-FD frames and normal fixed addressing ids.

## How it's tested

**In CI, on every pull request and push to `main`:**

| what | how much |
|---|---|
| Host unit tests | 131 V test files, 1,722 test functions |
| Example builds | every host example generated and built; the end-to-end tests in `examples/*/e2e_test.v` run |
| Freshness | committed generated code, the config reference and the traceability report must match a fresh run |
| Config gates | `ecucheck` on every example `ecu.toml` (a system's nodes through `syscheck`), `syscheck` on every example `system.toml` |
| No heap | a source lint, compiler allocation warnings on generated host code, and an allocator check on every linked ELF |
| Cross builds | all 16 STM32H7 images (13 applications, 3 bootloaders) |
| Requirements | `make trace-check` runs the tagged tests and regenerates [docs/traceability.md](docs/traceability.md) |

**Requirements:** 337, of which 13 are ASIL B and 324 QM; 244 verified, 30 covered and pending
a run, 63 uncovered, 0 failed. The method is in [requirements/README.md](requirements/README.md).
It follows ISO 26262 in spirit; nothing here is safety-certified.

**On silicon, by hand:** bench runs are recorded per board in
[requirements/verifications.toml](requirements/verifications.toml) with date and who signed: 47
recorded reviews, mostly bench runs per board, 40 approved and 7 pending. `make hwtest` runs the scripted on-target checks,
which flash an image and check it on the board.

**What CI does not cover:** the 35 Lua suites run by hand: 18 on `vcan` against Blobly Net, the
rest on the flashed boards.
The ST HAL and AUTOSAR CanIf CAN backends and the ThreadX-on-Linux demo are not built in CI.

## Limits

- **STM32H7 only** today (H723, H735, H755), and AMP only: one kernel per core, no SMP.
- **The target CAN path is leaner than the host's.** On ThreadX, application frames are sent
  cyclically with a simple layout and no E2E or SecOC stamping, and the ThreadX gateway forwards
  layout-identical routes only. Full TX modes, transcoding routes and TX protection run on the
  host bridge.
- **Handlers are periodic.** No reception-triggered handlers, queued signals or mode management.
- **No ARXML input**; ARXML reaches a node through Blobly Net's `arxml2dbc`. DBC multiplexing is
  parsed but not modelled.
- **E2E is Profile 1 only.** SecOC is not AUTOSAR-SecOC compatible: its freshness counter is
  8 bits in RAM and the key is written in `ecu.toml`.
- **DoIP** runs on ThreadX targets only, one tester at a time, with no TLS. SOME/IP has no
  Service Discovery.
- **No MPU enforcement** and no hardware watchdog wiring yet; the supervisor is a host-tested
  library.
- **The bootloader** has no dual-bank activation, anti-rollback or encryption yet.
- **Pre-release**: version 0.0.1 with no releases; the config format and wire formats still move.

## Layout

```
examples/<name>/  self-contained apps: ecu.toml, bus.dbc, app/ (the FBs), main.v, generated gen/ ports/ sig/
loom/             the scheduler             osal/      POSIX and ThreadX backends
comm/             com, e2e, secoc, isotp, uds, udsauth, diag, diagroute, fault, param,
                  nm, nm_can, nm_udp, doip, someip, bulk, shell, telem, trace
driver/           can (SocketCAN, FDCAN, ST HAL, CanIf), eth, doipnet, io
boot/  bcrypto/   the bootloader, and Ed25519/SHA-512
nvm/  wdg/  ecu/  the journal, the watchdog supervisor, the ECU lifecycle
boards/  net/     STM32H7 board packages, the NetX Duo Ethernet driver
tools/            the generators and checkers: dbc2cfg, ecucheck, cfg2v, loom2v, sigmap,
                  cfgschema, sysgen, syscheck, mkimage, trace, benches
requirements/     the requirements, and the bench verification record
cmd/  scripts/    demos; the build, check and bench scripts
schema/           JSON Schemas for ecu.toml and system.toml
```

## Docs

**User manual**: [docs/um/](docs/um/README.md), task recipes against real examples: add a signal,
frame, FB, thread or core; move data; gateway a frame; write an FB; add a shell command; record a
trace; build and flash; compose a system.

**Design**
- [architecture.md](docs/architecture.md): how FBs, the Loom, COM, the IOC and diagnostics fit (start here)
- [application-model.md](docs/application-model.md): the FB model
- [configuration.md](docs/configuration.md), [config-reference.md](docs/config-reference.md): `ecu.toml`, and every key
- [multi-node.md](docs/multi-node.md): systems from `system.toml`, gateways and `syscheck`
- [communication.md](docs/communication.md): COM, TX modes, receive monitoring, E2E, SecOC
- [diagnostics.md](docs/diagnostics.md), [can-tp.md](docs/can-tp.md): the UDS server, fault memory, ISO-TP
- [bootloader.md](docs/bootloader.md): the programming session, image format and trust model
- [nvm.md](docs/nvm.md), [nm.md](docs/nm.md): the journal, network management
- [net.md](docs/net.md), [someip.md](docs/someip.md): Ethernet, DoIP and SOME/IP
- [multi-image.md](docs/multi-image.md), [fb-placement.md](docs/fb-placement.md), [xcore.md](docs/xcore.md): multicore
- [multicore-perf.md](docs/multicore-perf.md), [threadx-amp.md](docs/threadx-amp.md): IOC transports and measurements
- [onboard_trace.md](docs/onboard_trace.md), [telemetry.md](docs/telemetry.md): trace and load telemetry
- [io.md](docs/io.md), [display.md](docs/display.md): IO points, the display
- [no-alloc.md](docs/no-alloc.md): the no-heap rule and how it is enforced
- [porting.md](docs/porting.md): a new board, RTOS or CAN backend
- [autosar-comparison.md](docs/autosar-comparison.md): what is kept from AUTOSAR, planned and skipped
- [ways-of-working.md](docs/ways-of-working.md): DBC drops, integrators and FB teams in parallel
- [traceability.md](docs/traceability.md): the generated requirement report

**Project**
- [ROADMAP.md](ROADMAP.md): what is next
- [CONTRIBUTING.md](CONTRIBUTING.md): issues are welcome; pull requests are not accepted yet

## License

MIT, see [LICENSE](LICENSE).
