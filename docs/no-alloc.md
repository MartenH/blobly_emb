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
