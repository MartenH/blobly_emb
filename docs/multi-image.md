# Multi-image generation — one ecu.toml, an image per core

> **Successor:** [multi-node.md](multi-node.md) lifts this one-config-many-images idea to a system of ECUs on a shared bus — the same transport-derivation, one rung lower (cross-node = a bus frame).

> Design + phase log for the multi-image emitter (2026-07-13). Prereqs all shipped and
> bench-proven: xioc (the cross-core SPSC channel, boards/common/xioc.h), external
> partitions (identity without code), the generated duo contract header, the two-core
> trace, and `examples/h755_m4_app` — the hand-written satellite image this emitter
> absorbs, exactly as `threadx_h735` was absorbed by the generated `h735_threadx`.

## Directives (user, recorded in the plan)

1. **N-core, core-kind-agnostic.** Cores are model entries; any core can own a bus; the
   M7+M4 H755 is the first instantiation, not the shape. No Cortex-M assumptions in
   emission — arch flags live in the boards layer.
2. **SMP-open.** ecu.toml speaks ONLY partitions/cores/signal routing — never transports.
   The generator derives topology: heterogeneous AMP = N images + xioc; a future
   coherent/homogeneous target = one image + an SMP kernel + ordinary atomics. Image
   count and text sharing are EMISSION STRATEGIES, not configuration.

## The model (what dissolves, what stays)

**A satellite is an ordinary partition** whose image the generator emits elsewhere:

```toml
[[partition]]
name  = "m4"
core  = 1
image = "../h755_m4_app"   # emit this partition's image files into <dir>/gen etc.
```

- `image = <dir>`: generated satellite. One partition per image dir.
- `external = true` (kept): declared-but-hand-written — identity only, as shipped.
- Neither: the bus-owning image (exactly one such partition, as today).

**A cross-core signal is an ordinary signal.** `[duo]` dissolves:

```toml
[[signal]]
name   = "M4Sig"
fields = { n = "u32", acc = "u32" }   # 1..2 u32 fields ride one xioc {a,b} cell
from   = "m4"                          # a satellite partition...
to     = "can0"                        # ...to a bus the owner core drives
[[frame]]
name = "M4LoadFrame"                   # DBC-resolved, cyclic tx by the owner, as any tx signal
```

The generator sees `from`-partition core ≠ bus-owner core and derives the transport:

| crossing                       | transport (derived)                          |
|--------------------------------|----------------------------------------------|
| same thread                    | local cell in the thread state (today)       |
| threads on one core            | intra-core IOC cell (today)                  |
| partitions on different cores  | **xioc slot** in the board's shared window   |
| rx bus -> FB (owner core)      | comm decode -> IOC cell (today)              |

- Satellite side: the generated handler wrapper publishes `C.duo_pub(slot, a, b)`.
- Owner side: the EXISTING cyclic tx producer, reading `C.duo_poll(slot)` instead of
  `C.ioc_get(cell)` — same pacing, same encode, same frame path.
- A cross-core signal `to = "<owner partition>"` allocates a slot with no generated
  consumer — platform C (shell m4sig/iocx) is a legitimate reader via the contract header.
- Slot numbers appear ONLY in the generated `gen/duo_gen.h` (both images + glue C compile
  against it), exactly as shipped — now derived from signals instead of `[[duo.signal]]`.

## The satellite image (what gets emitted)

Into `<image>/`: `sig/signals_gen.v`, `ports/ports_gen.v`, `gen/loom_gen.v` containing:
per-thread `__global` tcb/stack/scheduler (all the stack-discipline lessons baked in),
state structs, handler wrappers (cross-core writes -> duo_pub), `run_<thr>` loops,
`tx_application_define` with deterministic `trace_bind_thread` order, trace FB hooks with
WALK-ASSIGNED global handler ids, the dtrace service poll (highest-priority thread's
loop), and `boot()` = clocks-ready park -> timebase -> duo pool init -> trace arm ->
kernel enter. The example keeps: a thin `main.v` (calls `gen.boot()`), its `app/` FBs
(ports-style handlers, same convention as every FB), its glue C (board/duo/dtrace — the
`comm_glue.c` equivalent), and its Makefile. Generation runs ONCE from the owner
example's config; the satellite's gen step is "make gen in the owner dir".

## Explicitly out of scope (this phase)

- Generating satellite Makefiles/glue C (examples own them, as everywhere).
- >2-field or non-u32 cross-core signals (xioc cell = {a,b}; widen the cell later).
- Satellite-owned buses (any core CAN own one per the directive; emission for it comes
  with a real use case).
- SMP emission (recorded strategy; needs silicon that earns it).

## Retired with this phase

- `[[duo.signal]]` config (replaced by real signals; generation errors with a pointer).
- The rung-3 heartbeat + `cm4` shell command (scaffolding; m4sig/iocx/stat/trace are the
  observability). The iocx stress source becomes an ordinary generated FB.

## Status (2026-07-13): SHIPPED + bench-verified

One `make gen` in examples/h755_threadx now emits BOTH images. h755_m4_app's main.v is a
`gen.boot()` shim; its FBs (M4Load, M4Churn) are ports-convention app code; the generated
wrappers publish `C.duo_pub(slot, ...)`; the owner's comm loop transmits M4LoadFrame from
the same signal declaration. Bench (NUCLEO-H755ZI-Q): M4Count +10 per 100 ms frame exactly;
`iocx` 200k reads / 0 tears / 0 regressions through the generated 500 Hz M4Stress channel;
two-core trace dump streams core-1 blocks with the walk-assigned handler ids (4 = M4Load
1689 µs @10 ms, 5 = M4Churn 659 µs @2 ms → the M4 sits at ~50%); h735_threadx and the host
examples regenerate byte-identical. blobly_net needed zero changes.

## Wide remote signals (2026-07-23, the xioc_n rung)

> Design + increment log. Mechanism shipped first (`boards/common/xioc.h` `xioc_n_*`,
> host-tear-tested); this section is the loom2v derivation on top. Motivation, verbatim
> from review: signals over 8 B are NOT rare — moving a partition must change cost,
> never the communication contract.

**The lane model.** A remote signal's fields ride **one u32 lane each** in a wide xioc
channel (`words = field count`, ≤ `XIOC_MAX_WORDS` 16 = one PDU). Field types up to 32
bits (`u32`/`u16`/`u8`/`bool`) cast to/from their lane; 64-bit fields stay rejected until
a signal earns them. `valid` is now an ordinary lane (the old ban traded location
transparency for purity: a same-core signal with `valid` must survive its producer
moving cores — transport freshness is still the slot stamp, `valid` is app data).
Deterministic by construction: no V-struct layout mirroring in the generator, no
packing drift — the same rule the {a,b} pair already followed, generalized.

**Placement.** The pair pool (`DUO_IOC_ADDR`, bench-verified) is untouched; signals
that fit it (1–2 u32-typed fields, no valid) keep generating byte-identical pair code.
Wider signals get offsets in a **wide window** the board reserves (`DUO_XW_ADDR` /
`DUO_XW_MAX` in `duo.h`), laid out by the generator in `duo_gen.h`
(`DUO_XW_<SIG>_OFF`, `XIOC_N_BYTES`-sized, with a budget static-assert). Glue gains two
thin wrappers (`duo_pub_n` / `duo_poll_n` over `xioc_n_write/read`); the pair fns stay.

**Destinations.** Satellite → local partition: the dest wrapper unpacks lanes into the
`In` struct — any ≤32-bit field types. Satellite → bus: additionally requires the
existing lean-codec contract (u32 lanes at 32-bit offsets, factor 1) and, past 2 lanes,
an FD frame (>8 B payload) — both enforced with the existing loud panics.

**Verification honesty.** Host: generator-level tests + the committed example regen;
the xioc_n mechanism itself is host-tear-tested (tools/xioc). Runtime on silicon —
the H755 re-run of the tear harness at real widths — is a bench-queue item; until
then the wide path is compile-verified only and no in-tree config enables it on
the bench demo.
