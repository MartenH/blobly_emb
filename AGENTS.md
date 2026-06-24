# AGENTS.md — blobly_emb

Embedded automotive stack in V: sim-first, multicore (AMP), **no runtime heap**.
A lean alternative to AUTOSAR Classic — app components with typed ports + periodic
handlers, wired by the **Loom**, over a comms stack we own. See `docs/` for the
deeper rationale (`no-alloc.md`, `memory-protection.md`, `multicore-perf.md`,
`threadx-amp.md`).

## Layout

```
app/      components: typed ports + periodic handlers   (what developers write)
loom/     the Loom: wiring + dispatch (the de-AUTOSAR'd "RTE")
comm/     comms stack: com (signals), + generated DBC codec
driver/   driver port: can (sim=SocketCAN, target=MCAL)
osal/     OS abstraction: time, cores, IOC (sim=POSIX, target=ThreadX AMP)
gen/      generated static config tables (cfg2v from ecu.toml) — no-alloc
tools/    BUILD-TIME only (heap OK): dbc2cfg, cfg2v, benches, candb, threadx_amp
config/   ecu.toml (single source), *.dbc
```

## Build & test

```sh
v -o blobly_emb .          # build the runtime
make lint                  # no-alloc + partition-isolation checks (MUST pass)
make vcan && make run       # run the AMP demo on vcan0
v -prod run tools/ioc_bench/bench.v        # IOC perf (1x/2x/3x)
v -gc none run tools/ioc_bench_mp/bench.v  # cross-process IOC
```

## Review guidelines

Enforce these as high-priority (P0/P1); they are the project's hard invariants.

- **No runtime heap.** In `app/`, `comm/`, `loom/`, `gen/`: no `string`, no `map`,
  no growable `[]T`, no closures. Only fixed arrays (`[N]T`), value structs, static
  tables. `osal/` and `driver/` may allocate **only at init** (before the main
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
- **No AUTOSAR vocabulary** in the developer-facing surface: it's **Loom** (not
  RTE), **handler** (not runnable), **component** (not SWC). Flag regressions.
- **Generated code.** `comm/com/dbc_gen.v` (`tools/dbc2cfg`), `gen/ecu_gen.v`
  (`tools/cfg2v`), and `gen/loom_gen.v` (`tools/loom2v`) are generated from
  `config/` via `make gen` — never hand-edit them; changes belong in the config
  or the generator.
- **Memory safety.** Scrutinize `unsafe` blocks, pointer casts, and that payloads
  fit `IOC_MAX` (64 bytes); `sizeof` must not exceed it.

## Conventions

- V, compiled via its C backend. Keep C interop in `osal/*_native.c` /
  `driver/can/*.c` behind the OSAL / driver-port boundary.
- Two backends only exist below the line: `osal/` and `driver/`. Everything above
  is platform-independent V and must stay that way.
