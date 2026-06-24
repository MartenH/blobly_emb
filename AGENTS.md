# AGENTS.md — blobly_emb

Embedded automotive stack in V: sim-first, multicore (AMP), **no runtime heap**.
A lean alternative to AUTOSAR Classic — app components with typed ports + periodic
handlers, wired by the **Loom**, over a comms stack we own. See `docs/` for the
deeper rationale (`no-alloc.md`, `memory-protection.md`, `multicore-perf.md`,
`threadx-amp.md`).

## Layout

```
examples/<name>/   a self-contained app (one module main): ecu.toml, bus.dbc,
                   signals.v, <fb>.v (Function Blocks), main.v (bus bridge),
                   gen_*.v (GENERATED), signal-map.md. `make example NAME=<name>`.
loom/     the Loom: scheduler (the de-AUTOSAR'd "RTE")
comm/     comms stack (framework): nm (network management)
driver/   driver port: can (sim=SocketCAN, target=MCAL)
osal/     OS abstraction: time, cores, IOC (sim=POSIX, target=ThreadX AMP)
tools/    BUILD-TIME only (heap OK): dbc2cfg, cfg2v, loom2v, sigmap, benches, candb
cmd/      backend harness (threadx_demo)
```
The framework (loom/comm/driver/osal) is shared; each example owns its config,
FBs and generated code. Generated files are flat `module main` (no app/sig/gen
modules anymore).

## Build & test

```sh
make list                            # list examples
make example NAME=overspeed           # generate + build an example app
make vcan && make run-example NAME=overspeed   # run it on vcan0
make lint                            # no-alloc + isolation checks (MUST pass)
make demo                            # backend harness on POSIX (or demo-threadx)
v -prod run tools/ioc_bench/bench.v   # IOC perf (1x/2x/3x)
```

## Review guidelines

Enforce these as high-priority (P0/P1); they are the project's hard invariants.

- **No runtime heap.** In `comm/`, `loom/`, and each example's runtime files
  (FBs, signals, generated): no `string`, no `map`, no growable `[]T`, no
  closures. Only fixed arrays (`[N]T`), value structs, static tables. An example's
  `main.v` (the bus bridge / entry) is exempt (init-time heap, like osal/driver). `osal/` and `driver/` may allocate **only at init** (before the main
  loop), never in steady-state handlers. `tools/` is unrestricted. Flag any heap
  in a runtime layer.
- **IOC is single-writer-per-channel (SPSC).** Each channel has exactly one
  producing partition. The lock-free seqlock/double/triple algorithms are only
  valid under SPSC — flag any second writer, any cross-core shared mutable state
  reached without the IOC, and any removal of the cache-line padding or the
  `vcopy` (volatile) payload copy.
- **Partition isolation.** `app/` must never import a driver; cross-core data
  flows only through the IOC (`osal.ioc_*`). Flag direct cross-partition memory
  access — it breaks the memory-protection model.
- **No AUTOSAR vocabulary** in the developer-facing surface: **Loom** (not RTE),
  **handler** (not runnable), **Function Block / FB** for the application unit
  (not SWC, and not "component"/"software unit" — both overload the ISO 26262
  ladder; see docs/application-model.md). NOTE: config/code still use
  `[[component]]` pending the `component → fb` rename — that transitional state is
  expected, not a regression. Flag *adopting* an AUTOSAR term as one of our names
  (calling a thing RTE / runnable / SWC); merely *mentioning* such a term to
  explain why it's avoided is fine.
- **Generated code.** Each example's `gen_dbc.v` (`dbc2cfg`), `gen_ecu.v`
  (`cfg2v`), `gen_ports.v` + `gen_loom.v` (`loom2v`), and `signal-map.md`
  (`sigmap`) are produced by `make example NAME=<name>` — never hand-edit them;
  changes belong in the example's `ecu.toml` or the generator.
- **Memory safety.** Scrutinize `unsafe` blocks, pointer casts, and that payloads
  fit `IOC_MAX` (64 bytes); `sizeof` must not exceed it.

## Conventions

- V, compiled via its C backend. Keep C interop in `osal/*_native.c` /
  `driver/can/*.c` behind the OSAL / driver-port boundary.
- Two backends only exist below the line: `osal/` and `driver/`. Everything above
  is platform-independent V and must stay that way.
