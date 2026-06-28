# Requirements & verification

How blobly does **requirement-based testing** (ISO 26262 in spirit): requirements
are capability contracts, and a requirement is *fulfilled only when a connected
verification runs and passes*. This file is the method; the `*.md` files beside
it hold the requirements themselves.

## The model (read this first)

- A **requirement** says *what* the stack must do — implementation- and
  instance-agnostic. Swapping a backend, adding a second CAN bus, or adding a
  core must **not** need a new requirement ID.
- A requirement is **fulfilled** when a **verification linked to it has run and
  passed**. Code existing is *not* fulfillment. There is no "implemented" state —
  only *verified* (a passing check exists) or not.
- We track **verification → requirement**, and **nothing else**. We do **not**
  record which source file implements a requirement; the only trace link is the
  one a *test/check* declares about what it verifies. The proof is the green
  result, not a pointer into the code.

So the loop is simply: **a test runs → it passes → every requirement that test
declares is, in that run's context, fulfilled.**

## Requirement IDs

- Software: `REQ-<AREA>-<NNN>`. System/safety: `SYS-REQ-<AREA>-<NNN>`.
- **Name the *what*, never the *how* or *which instance*.**
  ✗ `REQ-DRV-FDCAN`, ✗ `REQ-CAN0-…`  →  ✓ `REQ-CAN-DRV-001` (every CAN backend,
  every bus instance must satisfy it).
- Areas (capability-level): `SYS, ECU, MODE, NM, WDG, INIT, COM, CAN-DRV, DIAG,
  E2E, SEC, IOC, SCHED, MEM, INV`.

Two tiers, linked by `derives` — the 26262 derivation chain:

```
SYS-REQ-COMMS-001  (the ECU shall exchange CAN frames on each configured bus)
   └─ REQ-CAN-DRV-001  derives SYS-REQ-COMMS-001
```

Requirements are **machine-readable TOML** — `requirements/<area>.toml`, one
`[[req]]` table each. This is the source of truth: `make trace` reads it (plus
test results) to generate `docs/traceability.md` and to check req↔test coverage.
Same format blobly already parses for `ecu.toml`.

```toml
[[req]]
id      = "REQ-CAN-DRV-001"
title   = "Transmit classic frame"
text    = "The CAN driver shall transmit a classic CAN frame with an 11-bit identifier and 0 to 8 payload bytes."
status  = "agreed"          # draft | agreed | verified | failed | uncovered
method  = "test"            # test | analysis | review
asil    = "QM"              # QM | A | B | C | D
derives = "SYS-REQ-COMMS-001"  # parent system req (omit for SYS-REQ-* entries)
```

A requirement must be **atomic, unambiguous, and verifiable**. If you can't name
a pass/fail check for it, it isn't a requirement yet. The requirement file holds
**no** pointer to implementation or test — the test/check declares what it
verifies (see below), and that is the only trace link.

See `modules.md` for the module decomposition and which areas exist.

## Verification methods

Every requirement declares **one** method. "Fulfilled" means *that method's
evidence is green*. Three methods cover everything we need:

| method | what it is | "passed" means | typical reqs |
|---|---|---|---|
| **test** | dynamic execution — blobly_net `.lua` on a (v)CAN bus, or a V unit test | the test exits green | functional behavior (COM, CAN-DRV, NM, DIAG, E2E, SEC) |
| **analysis** | an automated static check | the checker is green | invariants a runtime test can't show — `REQ-INV-*` no-alloc / SPSC / isolation (→ `make lint`), footprint, stack/WCET |
| **review** | a recorded human sign-off | approved + logged (who/when) | properties no tool checks — architectural rules, naming, process |

> `simulation` folds into **test** (on blobly the host build *is* the simulation —
> a host test is a simulated run). `inspection` folds into **review**.

The point of having three methods: an invariant like *"no dynamic allocation in
runtime code"* is never demonstrated by a passing functional test — its evidence
is `make lint` going green (method `analysis`). Treating that as a first-class
verification is what lets `REQ-INV-*` actually reach *verified*.

## Linking a verification to its requirement

The **verification artifact declares what it covers** — never the production code:

- **test** — the test declares the IDs it verifies (e.g. in its name/metadata:
  `verifies: REQ-CAN-DRV-001, REQ-CAN-DRV-003`).
- **analysis** — the checker declares its IDs (e.g. `make lint` → `REQ-INV-*`).
- **review** — a row in a review log: requirement + approver + date + commit.

That declaration is the *only* trace data. There is deliberately no
"implemented-here" tag anywhere in the source.

## Execution contexts — "many CANs, one requirement"

The same requirement-verifying test is **run in several contexts**, and each run
records its result **and** its context:

- `host / SocketCAN` (vcan),
- `h735 / FDCAN` (on target),
- … (any future backend/board).

Per-requirement coverage is therefore *per context*, and the columns of the
matrix are **execution contexts populated by results** — not source files. Adding
a CAN backend means **running the same requirements in a new context**, not
writing new requirements. On-target FDCAN verification of `REQ-CAN-DRV-001` turns
its `h735/FDCAN` cell from "not yet run" into a pass — *the same requirement,
proven on real silicon.*

## Fulfillment & coverage (computed from results)

For each requirement, gather its linked verifications and their **latest result**:

- **verified** — ≥1 verification exists and all passed (in the relevant context),
  **or** every requirement that `derives` from it is verified (the ISO 26262
  chain: a `SYS-REQ` is met when its derived module requirements are met —
  shown as "↳ derived").
- **failed** — a linked verification ran and failed (regression / not met).
- **uncovered** — no verification linked yet. A gap (test debt) when the
  requirement is `agreed`; expected while it is still `draft` (planned).

`make trace` runs (or ingests the results of) the verifications and emits
`docs/traceability.md`:

- a **flat list** — REQ → method → contexts → status, and
- a **matrix** — REQ × execution-context → `✓` pass / `✗` fail / `·` not run.

```
REQ            method    host/SocketCAN   h735/FDCAN
REQ-CAN-DRV-001 test           ✓               ·          (verified on host; target pending)
REQ-CAN-DRV-002 test           ✓               ·
REQ-INV-001     analysis      ✓ (make lint)    n/a        (verified)
```

`make trace-check` is the CI gate: **fail** if any requirement is `failed`, or if
any `agreed` requirement is `uncovered`.

## Status lifecycle

```
draft ──► agreed ──►  verified        (a linked verification passed)
                 ├─►  failed          (a linked verification fails)
                 └─►  uncovered        (agreed, nothing verifies it yet)
```

Note what's **absent**: there is no "implemented" status. Code without a passing
verification is, for tracking purposes, still just `agreed`/`uncovered`. Status
is driven by evidence, not by the existence of an implementation — which is the
whole idea.
