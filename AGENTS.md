# AGENTS.md — blobly_emb

Embedded automotive stack in V: sim-first, multicore (AMP), **no runtime heap**.
A lean alternative to AUTOSAR Classic — app components with typed ports + periodic
handlers, wired by the **Loom**, over a comms stack we own. **Start with
`docs/architecture.md`** for how the pieces fit. See `docs/` for the deeper
rationale (`no-alloc.md`, `memory-protection.md`, `multicore-perf.md`,
`threadx-amp.md`, `communication.md`, `autosar-comparison.md` — which RTE/COM
patterns we keep, plan, or skip — `ways-of-working.md` — how many teams + a
weekly DBC stay in sync via the signal-name contract — and `porting.md` — the
CAN/OSAL backend seam for a new target).

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
comm/   comms stack: com, e2e (CRC), secoc (AES-CMAC), isotp (15765-2), uds (14229), nm
driver/ driver port: can — SocketCAN (host) / ST FDCAN HAL / AUTOSAR CanIf (CDD); see docs/porting.md
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
make bench                                  # IOC transport + Loom dispatch benchmarks
(cd examples/overspeed && make test BLOBLY_NET=/path/to/blobly_net)  # on-bus integration test
```

Examples use classic CAN (`[bus] fd = false`) so blobly_net (classic) can drive
them; the driver picks classic vs CAN-FD from that flag. Integration tests live in
each example's `test/` (blobly_net project + Lua), run by `make test`.

### CI — what is and is NOT gated

`.github/workflows/ci.yml` runs on every push and PR: the host unit tests
(`v -enable-globals test comm driver tools ecu loom nvm wdg bcrypto boot`), `make lint`,
`make check` and `make trace`. Locally, run those four before opening a PR and nothing
should surprise you.

**Not gated — verify these yourself:**

- **Cross-compiling the STM32H7 examples.** Needs `arm-none-eabi`, `make deps` for the
  gitignored CMSIS headers, and a V master pin for the freestanding build. Target builds are
  bench-verified by hand.
- **`scripts/lint_vinit.sh`** — it takes a built ELF, so it runs from each example's Makefile
  after a cross-build, not in host CI. It catches the `$d`-const/field-default `_vinit` trap,
  which has cost four real casualties; do not skip it when you touch a target image.
- **Anything on real silicon.** Bench results go in `requirements/verifications.toml`.

Plain **`v test .` at the repo root looks broken** — it walks into `.claude/worktrees/` and runs
duplicate copies of every example e2e test concurrently. Test the real tree instead
(`v -enable-globals test comm driver tools ecu loom nvm wdg bcrypto boot examples`), which is
what CI does.

### Commit identity (enforced)

Every commit must be **authored** by `marten.hildell@gmail.com`; the committer may also be
`noreply@github.com` (GitHub rewrites it on a web squash-merge). `.github/workflows/guard.yml`
fails the build otherwise, and also auto-closes external PRs while the project is in its design
phase (see `CONTRIBUTING.md`). Install the local hook so it fails in a second instead of after a
push: `git config core.hooksPath .githooks`.

## Review guidelines

Enforce these as high-priority (P0/P1); they are the project's hard invariants.

> **Known non-finding — commit author identity.** Do not flag commits as authored by
> `codex@openai.com` (or any review-tool identity): that address appears only in review-side
> analysis checkouts, never in this repository's history. Commit identity is enforced
> authoritatively by CI (`.github/workflows/guard.yml` `commit-identity`, which runs on the
> real push and has rejected nothing that later landed) — a review claim that contradicts a
> green `commit-identity` check is an artifact, and it has been re-raised and re-refuted on
> eight PRs. Spend the finding budget on the code.

- **No runtime heap.** In `comm/`, `loom/`, and each example's runtime files
  (FBs, signals, generated): no `string`, no `map`, no growable `[]T`, no
  closures. Only fixed arrays (`[N]T`), value structs, static tables. An example's
  `main.v` (the thin entry — opens the socket, calls `gen.run`) is exempt
  (init-time, `string` ifname). The generated COM bus bridge lives in
  `gen/loom_gen.v` and **stays no-alloc** (channel + frames + value structs); it
  and `main.v` are the only example files that may `import driver`. `osal/` and
  `driver/` may allocate **only at init** (before the main loop), never in
  steady-state handlers. `tools/` is unrestricted. Flag any heap in a runtime layer.
  Examples build with **`-gc none`** (no collector — the runtime doesn't allocate);
  this also keeps the footprint small (no Boehm GC code/heap/threads linked).
  Exception (tier 1): a **bounded pool/arena carved from static memory** — fixed
  count, sized at config, provable ceiling, owned by one subsystem, exhaustion
  returns a value not a fault — is sanctioned for buffer-churn subsystems (net
  stack, etc.). That is NOT the heap (no `malloc`/fragmentation); the static
  worst-case footprint is preserved. See [docs/no-alloc.md](docs/no-alloc.md).
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
  *Exception:* `examples/scale` is a **fully generated** benchmark — `tools/scale_gen`
  emits its `ecu.toml`, `bus.dbc`, `main.v` **and** `app/` FBs (200 of them can't be
  hand-written). So there, uniquely, `app/` is generated; nothing in `scale/` is
  committed except the `Makefile` (everything is materialized by `make all`).
- **Memory safety.** Scrutinize `unsafe` blocks, pointer casts, and that payloads
  fit `IOC_MAX` (64 bytes); `sizeof` must not exceed it.

## Conventions

- V, compiled via its C backend. Keep C interop in `osal/*_native.c` /
  `driver/can/*.c` behind the OSAL / driver-port boundary.
- Two backends only exist below the line: `osal/` and `driver/`. Everything above
  is platform-independent V and must stay that way.
