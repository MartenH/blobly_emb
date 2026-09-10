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

**Which `[trace]` shapes generate.** loom2v emits a host trace runner for **one** partition
(single-core, `examples/trace_demo`), for **two** (`examples/trace_multicore`, #270 — one dump
owner plus one satellite core, with a system-wide freeze so both windows cover the same instant),
and for a **COM bridge plus one app partition** (`examples/trace_comm`, #191 P3b — the bridge
owns the trace bus and the module, the app partition is the satellite). An enabled `[trace]` on
any other shape **fails generation** rather than warning and building a silent no-op, naming the
one condition that tripped: partition count (three has no import slot — `TraceModule` holds
exactly one satellite), a bare-metal target, an eth trace bus, a bridge riding the trace bus
itself (the same-bus piggyback), a second bridge bus, a bridge sharing a core with the traced app
partition (a dump block header carries a core id, so two lanes on one core are indistinguishable),
or a two-lane trace with no `dump_fc` — only the ISO-TP block path carries a per-window header, so
the raw record stream would dump the owner's ring and drop the satellite's in silence. So a config
either gets trace or gets an error. `examples/h735_app` (P3c-0, bare-metal) is the slice still
`enabled = false`.

The dump owner is an **app partition — or the COM bridge that owns the trace bus** (P3b), never a
separate bus thread — that is what keeps the protocol in the platform: the owner's ring is then
`TraceModule`'s own buffer, so `handle_cmd`'s arm/stop/dump and the status counts act on a real
producing ring and only the satellite is imported. A bridge owner's lane comes from
`trace.thread_hook` (`note_thread`): it dispatches a COM drain, not FB handlers, so `fb_hook`
never fires for it and its swimlane would otherwise be empty. And note `run_profiled()` **accounts the pass itself**; a generated loop that calls
`sched.account()` after it charges every pass twice (that bug reached `trace_demo`, fixed in #270).
Note the
host still fills absent manifest frame rows with 0x7E2..0x7E6 defaults (#252 item 2), so "no rows"
does not yet read as "no trace" on the blobly_net side.

**Also gated now:** the STM32H7 cross builds — **every image, ThreadX and NetX Duo included** —
in their own CI job: apt's `gcc-arm-none-eabi` plus `make deps` (all three sources, about ten
seconds of cloning), then 26 images in a few minutes. Two passes, generate-then-build: a
satellite image like `h755_m4_app` has no `gen` target because its OWNER's generation writes the
`xcore_gen.h` it includes, so a from-clean build in directory order reaches it first and fails. Each one ends in
**`scripts/lint_vinit.sh`**, which the example Makefiles invoke and which can only run on the
freestanding path: V compiles a `__global`'s field defaults into `_vinit()`, a bare-metal image
never calls it, and those fields then read 0 on target — four bench casualties before that
script existed, and nothing in CI ran it until now.

**CI pins the V compiler** to the release tag in `.v-version` (currently `0.5.2`), installed as the
**prebuilt** `v_linux.zip` release asset in both jobs. It used to install master HEAD, so an upstream
V commit that does not compile stopped every merge here — that happened on 2026-09-08 (`unknown
module builder`), failing both jobs in the *install* step with nothing to do with the PR under test.
Note `vlang/setup-v` does not solve this on its own: given a tag or SHA it downloads the SOURCE and
self-hosts it, and that build is what breaks (0.5.2 from source dies on a duplicate `C.open`; master
`8631b280` on an empty `builder error:`). The release asset is already built. Bump `.v-version`
deliberately, and re-run the full local gate on the new compiler — the host suite AND the 26 cross
images, since the bare-metal path is the one that historically needed a specific V (#27564).
Your local V does **not** have to match the pin (working against master is often deliberate), but it
usually explains a local/CI disagreement — `make v-pin` prints both and says whether they differ.

**Not gated — verify these yourself:**

- **Anything on real silicon.** Bench results go in `requirements/verifications.toml`. Everything
  that can be *built* on a runner now is.

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
3. **`@codex review`**, iterated until clean before merging. Before the first request run
   `scripts/review_preflight.sh`; start every round with `scripts/request_codex_review.sh <pr>
   --post` and watch it with the command that prints. Do not hand-roll the polling.
4. **React 👍/👎 on every finding, and answer every thread** — see below. A round is not handled
   until each of its findings carries a reaction and a reply.

Three things that make the loop work:

- **Watch each round with a TRACKED background job**, never a detached shell (`( ... & )`). A
  detached watcher fires into nothing and the round sits unread — that happened twice in one
  session, once for over an hour. Run the `scripts/codex_review_watch.sh --state ...` line that
  `request_codex_review.sh` prints; it already matches the verdict by the head SHA codex names
  rather than by wording (phrase-matching missed "Didn't find any major issues" more than once).
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
here exists because a silent version of it lost a review. This repo keeps no status log; the
incidents are written up in blobly_net's `docs/history.md` (2026-08-12).

**Do not hand-roll the polling in a shell fragment.** `scripts/request_codex_review.sh <pr>
--post` is a thin wrapper over `scripts/codex_review.py`: it posts the request, records the PR
head SHA, records the request-comment marker and fresh baselines for each GitHub id space, and
prints the `scripts/codex_review_watch.sh --state .claude/reviews/pr-<pr>.env` line to run as a
tracked background job. The watcher reads the verdict channels as GitHub JSON rather than
shell-scraped text, and classifies the outcome in its exit code: `0` clean · `1` pending · `20`
findings · `30` the review FAILED and must be re-requested · `40` the head moved under it · `70`
a gh/API failure (never silently "nothing waiting"). `scripts/review_preflight.sh` refuses the
easy setup mistakes first — detached HEAD, the primary checkout, `main`, a dirty tree, a branch
that does not contain `origin/main`, gh missing or unauthenticated.

These are **copied verbatim from blobly_net** so the two stay diffable — resync with `diff
scripts/codex_review*.py ../blobly_net/scripts/...`, and fix a bug in both. The fixtures in
`scripts/codex_review_watch_test.sh` (79 cases) run in CI; the `MartenH/blobly_net` slug inside
them is inert stub data, not a cross-repo dependency. Update the fixtures when the GitHub or
Codex response shape changes.

The rules below are why the tool does what it does. Read them before changing it — each one is
a review that was lost.

- **`--paginate` everything**, but for two different reasons. Comments come back **ascending**,
  30 per page, so an un-paginated read drops the **newest** — the ones you are waiting for.
  `commits/<sha>/check-runs` is ordered by id **descending**, so there an un-paginated read keeps
  the newest page and drops **older** runs — a long-running job from an earlier workflow can be
  the one still pending. Either way the first page is not the answer. `--paginate` emits one
  page per line, so sum with `| awk '{s+=$1} END{print s+0}'` — not `bc` (absent in some agent
  environments), and not `--slurp` (gh refuses it alongside `--jq`). **Capture gh's exit status
  before the pipe**: on an auth or API failure gh returns 1 or 4 and prints nothing, `awk` then
  prints `0` and exits 0, and the result reads exactly like "nothing is waiting". Assign first,
  check `$?`, report the failure instead of a count. And `commits/<sha>/check-runs` pages are
  **objects**, not arrays — use `.check_runs | length` (or `.check_runs[]` to list); the array
  recipe would count an object's keys.
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
- **A review body may omit `Reviewed commit:` entirely.** On #276 round 6 the body opened with
  a `/blob/<sha>` permalink and a P1 finding and carried no footer at all — so a watcher gated on
  the footer reported `pending` while five findings sat waiting. Accept EITHER the footer or a
  permalink naming the sha; both are sha-anchored, so neither matches a stale review. The
  **clean** path deliberately still requires the footer: loosening a "findings" match costs a
  wait, loosening a "clean" match merges unreviewed code.
- **A finding can live in the review BODY, not only inline.** Counting `pulls/N/comments` alone
  missed the round-6 P1 on service/version type coercion, because it was written into the review
  summary. Read both.
- **A force-push during a pending review gets you a verdict for the OLD commit.** Codex answers
  for the SHA it started on, so after an amend or rebase its "no major issues" names a commit
  that is no longer on the branch. Observed on emb#255: clean on `a1d3c667` while the head was
  `d052f77`. This is exactly why the verdict is matched by head SHA — re-request after any push
  rather than accepting it.
- **Test the watcher against a state whose answer you already know**, and print per-channel
  counts. These failures are invisible from the outside — a command that succeeds and returns
  nothing looks exactly like no news.
- Run it as a **tracked** background job, never a detached shell (`( ... & )`). A cron sweep
  over every open PR is the backstop for when the watcher itself is wrong.

### Answering a round

**React 👍/👎 on every finding, and reply in its thread.** Codex's footer asks "Useful? React
with 👍 / 👎", and that is the only channel the review has for learning what it got right;
leaving it empty tells it nothing, round after round. Note the two endpoints have different
shapes:

```sh
gh api -X POST repos/<o>/<r>/pulls/comments/<id>/reactions -f content='+1'   # or '-1'
gh api -X POST repos/<o>/<r>/pulls/<pr>/comments/<id>/replies -f body='…'
```

**A PR-level summary is not an answer.** On #276 rounds 1–4 were answered in-thread and rounds
5–6 were written up as one PR comment instead — ten findings left with no reply and no reaction,
which is what the maintainer sees on opening the PR (user: "You have 0 responses to codex").
Before calling a round handled, ask for findings nothing replies to:

```sh
gh api --paginate repos/<o>/<r>/pulls/<pr>/comments --jq \
  '[.[]|select(.user.login|startswith("chatgpt"))] as $f
   | [.[]|select(.in_reply_to_id!=null)|.in_reply_to_id] as $r
   | ($f|map(select(.id as $i|($r|index($i))==null))|.[]|"UNANSWERED \(.id) \(.path)")'
```

**What the reaction rates is whether the FINDING is true** — not whether you liked the remedy,
and not whether you are going to act on it here:

| the finding is… | react | and |
|---|---|---|
| a real defect you reproduced, or one plainly derivable from the code | 👍 | fix it |
| real, but **pre-existing** — not this PR's doing | 👍 | file an issue; say which, so it is not lost when the branch is |
| real, but the suggested **fix** is wrong or too narrow | 👍 | fix it your way and say why the shape differs |
| real, and caused by **your own previous round's fix** | 👍 | the strongest signal you get — go after the class, not the instance |
| a claim you **checked and it does not hold** | 👎 | one line of evidence; never a silent dismissal |
| an artifact of the review's own checkout (see the commit-identity note below) | 👎 | run that note's tests first |
| style with no defect behind it | 👎 | say so plainly |
| something you **cannot yet tell** | *wait* | investigate, then react — a reaction you have to take back is worse than a late one |

Then reply once at PR level with the round's disposition (finding · reaction · what happened),
**in addition to** the per-thread replies, so the maintainer can read it without opening each
one.

**When findings repeat in one path, write the test — do not stop the review.** A round count is
the wrong instrument: net#84's nine rounds were nine rounds of real findings. But when
consecutive rounds keep landing in the same uncovered place, the loop is designing an untested
path one repair at a time — cover it with a test, which ends the repeats at their source. When
instead a round restates rules another gate already owns, the answer is to share the rule, not
to copy it again (#276 rounds 4–6 → #277).

**This is the opposite direction from the reaction rule above.** WRITING a reaction is feedback
to codex and is expected of you. READING codex's 👍 as the verdict is what cannot be made to
work.

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
