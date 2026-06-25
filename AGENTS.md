# AGENTS.md — blobly_emb

Embedded automotive stack in V: sim-first, multicore (AMP), **no runtime heap**.
A lean alternative to AUTOSAR Classic — app components with typed ports + periodic
handlers, wired by the **Loom**, over a comms stack we own. See `docs/` for the
deeper rationale (`no-alloc.md`, `memory-protection.md`, `multicore-perf.md`,
`threadx-amp.md`).

## Layout

```
examples/<name>/   a FREESTANDING app (own Makefile, `make all`):
   ecu.toml bus.dbc   configuration
   app/ (module app)   Function Blocks       hand-written (app)
   main.v (module main) entry: open CAN + gen.run  platform (hand, tiny)
   sig/ (module sig)   signal types          ┐ GENERATED (from [[signal]].fields)
   ports/ (module ports) In/Out structs      │
   gen/ (module gen)   codec/tables/glue +   │  (incl. the COM bus bridge:
                       COM bus bridge + run() ┘   bus endpoints -> rx/tx codec)
loom/   the Loom: scheduler (the de-AUTOSAR'd "RTE")
comm/   comms stack (framework): com (TX modes + RX deadline), nm (network mgmt)
driver/ driver port: can (sim=SocketCAN, target=MCAL)
osal/   OS abstraction: time, cores, IOC (sim=POSIX, target=ThreadX AMP)
tools/  BUILD-TIME only (heap OK): dbc2cfg, cfg2v, loom2v, sigmap, benches, candb
cmd/    backend harness (threadx_demo)
```
The framework (loom/comm/driver/osal) is shared; each example owns its config,
FBs, and generated code. Imports are short (`import sig`/`ports`/`osal`) via V's
`-path`. No generated file lives in a hand-written dir; app never mixes with
platform.

## Build & test

```sh
make list                                  # list examples
cd examples/overspeed && make all           # generate + build (freestanding)
make vcan && (cd examples/overspeed && make run)   # run on vcan0
make example NAME=overspeed                 # same as `cd … && make all`, from root
make lint                                  # no-alloc + isolation checks (MUST pass)
make demo                                  # backend harness on POSIX (or demo-threadx)
(cd examples/overspeed && make test CANTESTER=/path/to/cantester_v)  # on-bus integration test
```

Examples use classic CAN (`[bus] fd = false`) so cantester_v (classic) can drive
them; the driver picks classic vs CAN-FD from that flag. Integration tests live in
each example's `test/` (cantester project + Lua), run by `make test`.

## Review guidelines

Enforce these as high-priority (P0/P1); they are the project's hard invariants.

- **No runtime heap.** In `comm/`, `loom/`, and each example's runtime files
  (FBs, signals, generated): no `string`, no `map`, no growable `[]T`, no
  closures. Only fixed arrays (`[N]T`), value structs, static tables. An example's
  `main.v` (the thin entry — opens the socket, calls `gen.run`) is exempt
  (init-time, `string` ifname). The generated COM bus bridge lives in
  `gen/loom_gen.v` and **stays no-alloc** (channel + frames + value structs); it
  and `main.v` are the only example files that may `import driver`. `osal/` and
  `driver/` may allocate **only at init** (before the main loop), never in
  steady-state handlers. `tools/` is unrestricted. Flag any heap in a runtime layer.
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
- **Generated code.** Each example's `gen/dbc_gen.v` (`dbc2cfg` — decode *and*
  encode), `gen/ecu_gen.v` (`cfg2v`), `sig/signals_gen.v` + `ports/ports_gen.v` +
  `gen/loom_gen.v` (`loom2v` — incl. the COM bus bridge + `run()`), and
  `signal-map.md` (`sigmap`) are produced by `make all` — never hand-edit them.
  Signal value types come from each `[[signal]].fields`; **external vs internal is
  explicit** — an endpoint that names a `[bus.*]` is external (the bridge
  rx-decodes / tx-encodes it via the DBC), else it's partition-to-partition.
- **Memory safety.** Scrutinize `unsafe` blocks, pointer casts, and that payloads
  fit `IOC_MAX` (64 bytes); `sizeof` must not exceed it.

## Conventions

- V, compiled via its C backend. Keep C interop in `osal/*_native.c` /
  `driver/can/*.c` behind the OSAL / driver-port boundary.
- Two backends only exist below the line: `osal/` and `driver/`. Everything above
  is platform-independent V and must stay that way.
