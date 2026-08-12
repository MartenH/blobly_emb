# blobly_emb — project guide for coding agents

> **This is the guide.** `AGENTS.md` is a pointer FILE here, real rather than a
> symlink: two agents look for two names — Claude Code reads `CLAUDE.md` and nothing else, Codex
> and others read `AGENTS.md` — and a symlink either way round becomes a 9-byte text file on a
> checkout without symlink support, so whichever tool follows the link silently gets a one-word
> guide. That failure is not hypothetical: this repo had no `CLAUDE.md` at all, so a whole
> Claude session worked here without ever reading these rules.

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

`.github/workflows/ci.yml` runs on **pushes to `main` and on pull requests** — a push to a
feature branch runs only `guard`, so a green tick there is the identity check, NOT the test
gate. Open the PR to get one.

It runs more than the four you would run by hand: host unit tests
(`v -enable-globals test comm driver tools ecu loom nvm wdg bcrypto boot`), `make lint`,
`make check`, `make trace-check` (not `make trace`), `syscheck`, `v -enable-globals test
examples`, per-example host builds with generation, and a repo-wide **"Generated outputs are
fresh"** gate. The last one is the usual surprise: a stale committed `gen/` output passes every
local command and fails CI. Re-run generation before opening the PR.

**Two examples are NOT covered:** `examples/trace_comm` and `examples/trace_multicore` are
skipped by that loop (`ci.yml`, `SKIPPED (#191)`) because loom2v no longer generates the
multi-partition trace runner they were built with. Nothing regenerates or builds them, so a
change there has no CI gate at all until #191 is fixed — build and run them by hand.

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
phase (see `CONTRIBUTING.md`). Install the local hooks so it fails in a second instead of after a
push: `git config core.hooksPath .githooks`.

**Commit MESSAGES may not carry email addresses either.** The rule above covers *who* commits;
the message body is checked separately, because an address written into one is permanent — it
survives branch deletion, `git log` and code search index it, and removing it costs a rewrite of
every branch that carries it (GitHub's PR refs keep it even then). Only the maintainer address
and bot trailers (`Co-Authored-By: … <noreply@anthropic.com>`, `noreply@github.com`) are allowed.
Describe an address instead of quoting it — "a non-maintainer work address". The hooks cover both
the ordinary commit path (`commit-msg`) and cherry-pick/rebase (`pre-push`), which git does not
route through `commit-msg`.

## Working rules

The loop, in this order — not two of the three, and not a different order:

1. **Build it**, and verify it the way the change is actually used (on target or in the sim,
   not just "it compiles").
2. **`/code-review high` on the branch.** Self-run, high effort — not the billed cloud
   `/code-review ultra`, which only the maintainer triggers. Anything the self-review finds is
   found for free; each codex round is a ~10-minute wait. blobly_net#84 ran to nine rounds and
   34 findings without one, and its repeats — a lookup standing in for an identity four times,
   a policy centralised and then duplicated a round later, an unlocked read of state another
   thread replaces — were all visible in the diff without running anything. Look for exactly
   those, plus any claim in a doc the change just made false.
3. **`@codex review`**, iterated until clean before merging.

Three things that make the loop work:

- **Watch each round with a TRACKED background job**, never a detached shell (`( ... & )`). A
  detached watcher fires into nothing and the round sits unread — that happened twice in one
  session, once for over an hour. Match the verdict by the head SHA codex names, never by its
  wording: phrase-matching missed "Didn't find any major issues" more than once.
- **Work in a worktree, never the main checkout.** `git worktree add .claude/worktrees/<name> -b
  <branch> origin/main` — **fetch first** (`git fetch -q origin`): naming a remote-tracking ref
  does not contact the remote, so a checkout that has not fetched since `main` advanced branches
  from a stale local value and silently omits landed work. And WITH the start point, or it
  branches from whatever the shared checkout is on — the very state this bullet warns about (it
  is detached today, and local `main` lags origin). Sessions run concurrently, and a second one that finds the shared checkout on a
  foreign branch, or mid-rebase, loses work that was not its own. The main checkout stays clean
  for reading and for merges. (It is also why `v test .` at the root misbehaves — see Build &
  test.) On hardware: never flash the bench from two sessions at once.
- **Update this file in the PR that lands the work**, especially new modules or a changed
  build/flash step. A guide that drifts is worse than none: it gets believed.

### Polling a codex review

A watcher that reports "nothing" when something is waiting is worse than no watcher. Every rule
here exists because a silent version of it lost a review; the incidents are in
[`docs/history.md`](docs/history.md).

- **`--paginate` everything.** 30 per page, ascending, so an un-paginated read drops the
  **newest** items. Applies to comments AND `commits/<sha>/check-runs`. `--paginate` emits one
  array per page, so sum with `| awk '{s+=$1} END{print s+0}'` — not `bc` (absent in some agent
  environments), and not `--slurp` (gh refuses it alongside `--jq`).
- **`gh api --jq` takes exactly one argument.** jq's own flags (`--arg`) make it exit 1 with no
  stdout, so the filter returns nothing and the channel looks empty. Interpolate instead.
- **Do NOT use the 👍 reaction as the verdict**, despite codex's footer saying "otherwise it
  will react with 👍". It cannot be made reliable: the reaction payload carries **no reviewed
  SHA**, so a fresh `+1` may belong to the previous head if the head moved while the review ran;
  and GitHub will not create a second identical reaction from the same actor, so on a later
  clean round the existing one keeps its ORIGINAL timestamp and no freshness test can ever pass.
  Both directions are broken, in opposite ways. Observed on net#84: the clean result arrived as
  a 👍 **and** as a comment naming the head, one second apart — the comment is the signal.
- **Flatten a comment body before matching it.** `Reviewed commit:` sits in the MIDDLE of a
  multi-line body, so piping it through `tail -1` matches against the footer and never fires.
  `gsub("\n";" ")` it into one line, id-prefixed, and take the highest id.
- **Never edit a watcher script while an instance is running.** bash reads a script
  incrementally, so the running copy executes half of the new file and dies on a comment.
  Write a new file instead.
- **Three channels**, and the first already contains the second:
  `pulls/N/comments` (source of truth — review-attached comments appear here too, so summing
  both double-counts) · `pulls/N/reviews/<id>/comments` (fallback; narrowing to the latest
  review hides earlier unhandled findings) · `issues/N/comments` (the verdict, or "Something
  went wrong" = the review FAILED and must be re-requested, not waited on).
- **Identify a result by head SHA prefix AND a freshness baseline.** Codex names a 10-char
  abbreviated SHA, so a 40-char compare never matches; but a retry after a failed review names
  the *same* SHA as the failure, so record the highest comment/review id first and require the
  match to beat it. Never match on wording.
- **Test the watcher against a state whose answer you already know**, and print per-channel
  counts. These failures are invisible from the outside — a command that succeeds and returns
  nothing looks exactly like no news.
- Run it as a **tracked** background job, never a detached shell (`( ... & )`). A cron sweep
  over every open PR is the backstop for when the watcher itself is wrong.

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
