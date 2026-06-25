# blobly_emb

An embedded **automotive stack written in [V](https://vlang.io)** — multicore (AMP),
sim-first, and built to run **without dynamic memory allocation**.

A lean, non-AUTOSAR alternative: you write application **Function Blocks (FBs)** —
private state + periodic handlers that are pure functions of input signals to
output signals — and the **Loom** (generated from `ecu.toml`) wires them across
cores and to/from the bus. No AUTOSAR vocabulary, no `malloc`.

## Layout

```
examples/<name>/  self-contained apps (one module main): ecu.toml + FBs + main.v
                  + generated code (make example NAME=<name>)
loom/    the Loom scheduler            osal/   OS abstraction: time/cores/IOC
comm/    comms stack: nm (and more)             (sim=POSIX, target=ThreadX AMP)
driver/  driver port: can (sim=SocketCAN, target=MCAL)
tools/   build-time generators: dbc2cfg, cfg2v, loom2v, sigmap (+ candb, benches)
```

The framework (`loom`/`comm`/`driver`/`osal`) is shared; each example owns its
config, FBs, and generated code. Only `osal`/`driver` have two backends.

## Quick start

```sh
make vcan                              # bring up vcan0 (needs sudo)
cd examples/overspeed && make all       # generate everything + build -> bin/app
./bin/app vcan0 &                       # run it
# in another shell:
candump vcan0
cansend vcan0 100##0.0000240500000000   # VehicleSpeed ~131 km/h -> lamp on (101#01)
cansend vcan0 100##0.204E000000000000   # EngineSpeed 5000 rpm   -> lamp on
cansend vcan0 100##0.0000000000000000   # all zero               -> lamp off
```

Each example is freestanding (`cd examples/<name> && make all`). See
[examples/](examples/) — `overspeed` exercises every signal path (FB↔COM,
same-core FB→FB via a local cell, cross-core FB→FB via IOC); `minimal` is the
basic one-FB case.

## How it works

- **Config-driven**: `ecu.toml` (+ a DBC) generates the COM codec, IOC channels,
  Loom wiring, and FB port structs — all no-alloc V. Routing is derived from each
  signal's `from`/`to` (local cell vs IOC vs bus). See [docs/configuration.md](docs/configuration.md).
- **Application model**: [docs/application-model.md](docs/application-model.md).
- **Multicore**: lock-free IOC with per-channel transport ([docs/multicore-perf.md](docs/multicore-perf.md)),
  AMP partitions ([docs/memory-protection.md](docs/memory-protection.md)),
  real ThreadX backend ([docs/threadx-amp.md](docs/threadx-amp.md)).
- **Trace any signal** to its DBC origin: each example's generated `signal-map.md`.

## No dynamic allocation

Runtime files (FBs, signals, generated, `comm/`, `loom/`) use only fixed arrays,
value structs, and static tables — never `string`, `map`, or growable `[]T`.
Enforced in CI: `make lint`.

## Status

Research / learning stage. Working: FB application model + config codegen, lock-free
multicore IOC, CAN/CAN-FD + DBC, Network Management, ThreadX AMP backend.
Roadmap: NvM (memory stack), diagnostics (ISO-TP/UDS), real-silicon bring-up.
