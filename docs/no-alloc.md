# No dynamic allocation — the rule, by layer

blobly_emb forbids heap allocation **at runtime**, not at build time. The split:

| Layer | Dirs | Heap (`string`, `map`, `[]T`, closures) |
|-------|------|------------------------------------------|
| **Runtime — strict** | `app/`, `comm/`, `loom/` | **Forbidden.** Fixed arrays `[N]T`, value structs, static tables only. Enforced by `scripts/lint_noalloc.sh`. |
| **Runtime — init only** | `osal/`, `driver/` | Allowed **only before the main loop** (open interface, spawn partitions). Never in steady-state handlers. |
| **Build-time — free** | `tools/`, codegen, tests, sim harness | **Unrestricted.** This is where `candb` and the DBC importer live. |

## Why strict-from-day-one on runtime

Heap is contagious through types, APIs and ownership, and V emits no warning for
it — so retrofitting no-alloc later is a near-rewrite of each module plus the hard
work of deriving every buffer's worst-case bound. The runtime layers are small
and already static, so staying strict costs almost nothing; converting later
would not. See the longer rationale in the project discussion / git history.

## How the boundary is policed

- `make lint` scans `app/ comm/ loom/` for `string` / `map[` / `[]T` and fails the
  build if any appear.
- The same lint forbids `app/` from importing a driver — the software mirror of
  the MPU rule that an app partition has no peripheral access (see
  [memory-protection.md](memory-protection.md)).
- `tools/` is deliberately **not** scanned: build-time code may allocate freely.

## DBC example of the split

`candb` (heap-based) parses a DBC at **build time** in `tools/dbc2cfg`; it emits
`comm/com/dbc_gen.v` — generated **no-alloc** accessors over `[64]u8`. `candb`
never ships to the target; its `raw_value`/`set_raw` is just the reference
algorithm the generator transcribes.

## Bounded pools and arenas — the sanctioned middle tier

The rule above bans the **heap**, not *allocation*. What the ban actually
protects is three properties: deterministic latency (no fragmentation stall or
mid-drive failure), an **analyzable worst-case footprint** (what a safety case
or an MPU layout needs), and freestanding reality (V's `dlmalloc` faults
bare-metal). A general-purpose `malloc`/`free` forfeits all three. A
**fixed-size pool or arena carved from static memory** keeps all three *and*
gives allocation ergonomics — so it is allowed, under discipline, for
subsystems that genuinely churn buffers or do transactional work.

It is **not "turning on the heap."** A pool is a static `[N*BLK]u8` chopped into
blocks with a freelist; an arena is a static buffer you bump-allocate and then
**reset wholesale**. No `dlmalloc`, no fragmentation, and the ceiling is fixed
at config time. "Pool full" / "arena full" is a bounded, handleable return — not
an OOM. The safety claim survives: worst-case memory is still static.

| Tier | What | Where | Lifetime discipline |
|---|---|---|---|
| **0 — static / init-only** | globals, fixed arrays, allocate-at-boot-never-free | everything steady-state (`app/ comm/ loom/`, control loops) | the default; nothing frees |
| **1 — bounded pool / arena** | fixed-count block pool, or bump-arena reset wholesale | transactional or buffer-churn subsystems (net-stack buffers, diagnostic sessions) | sized at config; **provable ceiling**; arena freed all-at-once (no leak by construction) |
| **never** | general `malloc`/`free`, unbounded lifetimes | — | — |

Rules for a tier-1 pool:

- **Sized at config, ceiling proven.** The block count / arena size is a
  build-time constant; the design must show the max concurrent occupancy fits.
- **Owned by one subsystem.** No shared global allocator. The pool lives with
  the module that needs it, so its footprint is local and reviewable.
- **Failure is a value, not a fault.** Exhaustion returns `none`/`false`; the
  caller degrades (drop the packet, refuse the session) — it never traps.
- **Static-backed.** The storage is a `static` fixed array, so `-gc none` and
  the freestanding target are unaffected; `make lint` treats a reviewed pool
  module as the sanctioned exception (like `osal/`/`driver/` init).

### Where each tier lands

- **Crypto (`bcrypto/`)** stays **tier 0** — not by dogma but because its working
  set is a few hundred bytes of stack (`gf` temporaries, a hash context), so it
  never wanted a heap; the boot verifies signatures with no allocation at all.
  (V's stdlib `crypto.ed25519` allocates — it pulls `dlmalloc` — which is why the
  on-target verify is the no-alloc port and the host tooling uses the stdlib.)
- **A TCP/IP stack** will be **tier 1**: packet buffers, reassembly, retransmit
  and socket buffers cannot be pure-static. The reference embedded stack (lwIP)
  solves this with `pbuf`/`MEMP` pools — fixed-count, build-configured. blobly's
  net stack is designed around a buffer pool from day one, not a heap.
- **The maintenance line.** Frozen standards (Ed25519/RFC 8032) are cheap to
  carry no-alloc and pinned to vectors. Evolving or security-critical subsystems
  you should **not** hand-roll (TLS, a full TCP stack) — pull a vetted
  implementation and give it a pool, rather than maintain a bespoke no-alloc
  fork forever.
