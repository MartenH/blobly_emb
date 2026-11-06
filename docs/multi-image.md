# Multi-image generation — one ecu.toml, an image per core

> **Successor:** [multi-node.md](multi-node.md) lifts this one-config-many-images idea to a system of ECUs on a shared bus — the same transport-derivation, one rung lower (cross-node = a bus frame).

> Design + phase log for the multi-image emitter (2026-07-13). Prereqs all shipped and
> bench-proven: xioc (the cross-core SPSC channel, boards/common/xioc.h), external
> partitions (identity without code), the generated xcore contract header, the two-core
> trace, and `examples/h755_m4_app` — the hand-written satellite image this emitter
> absorbs, exactly as a hand-written ThreadX image (since retired) was absorbed by the
> generated `h735_threadx` (itself retired in #340).

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

The generator sees which core produces a signal and which cores' FBs read it, and derives the
transport:

| crossing                       | transport (derived)                          |
|--------------------------------|----------------------------------------------|
| same thread                    | local cell in the thread state (today)       |
| threads on one core            | intra-core IOC cell (today)                  |
| satellite -> owner (bus or FB) | **xioc slot** (or wide `xioc_n` channel) in the board's shared window |
| owner (FB or rx bus) -> satellite FB | **`xioc_n` channel** in the owner-written window |
| rx bus -> FB (owner core)      | comm decode -> IOC cell (today)              |

The producer's core is where its `from` sits (an owner partition, a bus the owner's comm thread
receives, or a satellite partition); the readers are the FBs that list the signal in `reads`, never
the signal's single `to`. So an owner FB and a satellite FB may read one signal, its one writer
feeding both.

- Satellite side: the generated handler wrapper publishes `C.xcore_pub(slot, a, b)` (wide:
  `C.xcore_pub_n`), and reads an owner signal with `C.xcore_down_read`, gated on the owner's ack.
- Owner side: the EXISTING cyclic tx producer, reading `C.xcore_poll(slot)` instead of
  `C.ioc_get(cell)` — same pacing, same encode, same frame path. An owner FB reads a pair slot
  through `C.xcore_poll` (one owner reader thread: its last-good state is one static per slot) and
  a wide channel through `C.xcore_poll_n`, into reader state in its own thread's state struct.
  A down channel is written with `C.xcore_opub_n` by the comm thread (a received signal) or by the
  thread of the owner FB that writes it.
- A satellite signal no owner FB reads still gets its slot — platform C (shell m4sig/iocx) is a
  legitimate reader via the contract header.
- Slot numbers and window offsets appear ONLY in the generated `gen/xcore_gen.h` (both images +
  glue C compile against it), exactly as shipped — now derived from signals instead of
  `[[duo.signal]]`.

## The satellite image (what gets emitted)

Into `<image>/`: `sig/signals_gen.v`, `ports/ports_gen.v`, `gen/loom_gen.v` containing:
per-thread `__global` tcb/stack/scheduler (all the stack-discipline lessons baked in),
state structs, handler wrappers (cross-core writes -> xcore_pub, reads of owner signals ->
xcore_down_read), `run_<thr>` loops,
`tx_application_define` with deterministic `trace_bind_thread` order, trace FB hooks with
WALK-ASSIGNED global handler ids, the dtrace service poll (highest-priority thread's
loop), and `boot()` = clocks-ready park -> timebase -> xcore pool init -> trace arm ->
kernel enter. The example keeps: a thin `main.v` (calls `gen.boot()`), its `app/` FBs
(ports-style handlers, same convention as every FB), its glue C (board/xcore/dtrace — the
`target_ext.c` equivalent), and its Makefile. Generation runs ONCE from the owner
example's config; the satellite's gen step is "make gen in the owner dir".

## Explicitly out of scope (this phase)

- Generating satellite Makefiles/glue C (examples own them, as everywhere).
- >2-field or non-u32 cross-core signals (xioc cell = {a,b}; widen the cell later).
  *Superseded 2026-07-23: the wide rung below shipped exactly this — the bullet stays
  as phase history only.*
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
wrappers publish `C.xcore_pub(slot, ...)`; the owner's comm loop transmits M4LoadFrame from
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

**The lane model.** A remote signal's fields ride u32 **lanes** in a wide xioc channel
(`words = lanes`, ≤ `XIOC_MAX_WORDS` 16 = one PDU). `bool`/`u8`/`u16`/`u32`/`i8`/`i16`/
`i32`/`f32` take one lane each (signed as two's complement, `f32` by its bits), `u64`/`i64`/
`f64` two (low word first) — the same rule in both directions (user decision, 2026-11-05).
The channel is copied whole under its sequence stamp, so a 64-bit field never tears
across its two lanes. A signal sent on a CAN bus still carries only what the comm thread's
encode takes (`bool`/`u8`/`u16`/`u32`/`i8`/`i16`/`i32`, `lane_field_types`), the same rule
as on one core. `valid` is now an ordinary lane (the old ban traded location
transparency for purity: a same-core signal with `valid` must survive its producer
moving cores — transport freshness is still the slot stamp, `valid` is app data).
Deterministic by construction: no V-struct layout mirroring in the generator, no
packing drift — the same rule the {a,b} pair already followed, generalized.

**Placement.** The pair pool (`XCORE_IOC_ADDR`, bench-verified) is untouched; signals
that fit it (1–2 u32-typed fields, no valid) keep generating byte-identical pair code.
Wider signals get offsets in a **wide window** the board reserves (`XCORE_XW_ADDR` /
`XCORE_XW_MAX` in `xcore.h`), laid out by the generator in `xcore_gen.h`
(`XCORE_XW_<SIG>_OFF`, `XIOC_N_BYTES`-sized, with a budget static-assert). Glue gains two
thin wrappers (`xcore_pub_n` / `xcore_poll_n` over `xioc_n_write/read`); the pair fns stay.

**Destinations.** Satellite → bus: the comm drain polls the wide channel (`xcore_poll_n`,
per-signal seq + lane buffer in the comm loop; the reader passes its OWN lane count, so
a stale satellite image with different geometry reads as never-fresh instead of
overrunning the buffer) and encodes one u32 lane per 4 bytes into a frame of DLC ≥ `4 × lanes`,
sent every period from boot like an owner FB's frame (its initial payload until the first value).
**Reachable today up to 2 lanes** (classic DLC 8 — e.g. a `{u16, u16}` or `{u32, valid}`
signal): 3+ lanes need an FD frame, and the ThreadX comm thread still rejects both FD
buses and DLC > 8, so that emitter path is exercised by the generator tests only until
the FD comm owner lands (ROADMAP "target multi-bus comm owner"). Satellite → owner FB:
the wrapper unpacks the lanes into the FB's `In` struct (`xcore_poll_n`), its reader state
in the reading thread's state struct, so several owner reader threads are safe; until the
first value it keeps the port default.

**The matched-images contract (user decision, 2026-07-24).** Cross-build image skew is
**out of contract**: one generator run owns every image of a node, and deploying images
from different runs is a deployment error, exactly as two ECUs sharing a bus must share
the DBC — if a signal touches two cores, they must speak the same language. The
layout-id handshake (XCORE_LAYOUT_ID, schema-hashed, satellite-republished, owner-retracted
at boot) is **defense-in-depth for the accident** — a mismatched pair goes silent instead
of cross-talking — not a supported operating mode, and no further skew scenarios are in
scope here; enforcing matched images at update time is the boot chain's job when
multi-image update lands. This line was drawn deliberately after review rounds kept
finding ever-deeper skew hypotheticals: the mechanism hardening they surfaced was kept,
the protocol arms race was stopped.

**Verification honesty.** Host: generator-level tests + the committed example regen;
the xioc_n mechanism itself is host-tear-tested (tools/xioc), and the down direction's
seams are host-tested over a fake SRAM4 (`tools/xioc/xcore_down_test.v`; the derivation in
`tools/loom2v/xcore_down_test.v`). The down direction ran on the H755 on 2026-11-05
(`examples/system_full` `test/xcore_domain.lua`, 7/7: the checked, lean fan-out and FB → FB
shapes, the deadline and a corrupt frame seen on the CM4, a reset; not a tear stress). Runtime on silicon —
the H755 re-run of the tear harness at real widths — is a bench-queue item; until
then the wide path is compile-verified only and no in-tree config enables it on
the bench demo.

## Owner → satellite signals (the down direction)

What an FB can and cannot do on each core, as a matrix of requirements: [fb-placement.md](fb-placement.md).

A signal produced on the owner image — an owner FB's output, or a frame the owner's comm
thread receives — that a satellite FB reads gets a **down channel**: an `xioc_n` channel in
the owner-written window (`xcore.h` `XCORE_OW_*`, offsets in `xcore_gen.h`), 1..16 lanes by
the lane model above. Nothing is configured; moving the reading FB between cores moves the
channel.

- **Writers.** The comm thread writes a received signal: a lean frame as one lane (the value
  field), a checked frame (deadline, E2E, SecOC, `status`/`lost`, several read signals, a
  non-trivial layout, a fault source) as every field including its `RxStatus`, on receipt and
  on timeout. An owner FB's output is written by that FB's thread; a down channel has one
  writer thread (SPSC). The owner allocates IOC / byte-IOC cells only for owner readers.
- **Boot.** Before the satellite is released, the owner's `boot()` retracts its ack, takes a
  new retained odd nonce, initialises each down channel seeded from it, and commits
  `ack(nonce ^ XCORE_LAYOUT_ID)` (`boards/h755zi/xcore_owner.c`).
- **Reader.** `xcore_down_read` (`boards/h755zi/xcore_sat.c`) checks the ack on every read and
  resets to the port default when the owner nonce changes, so a new owner boot never shows the
  previous boot's value. Its state is in the reading thread's state struct.
- **A parameter read on a satellite** rides a down channel of its own, one lane per field,
  written by `param_pub` at the restore and on every 0x2E; the owner releases the satellite only
  after the restore (REQ-PLACE-007).
- **Not generated yet**, each refused at generation ([fb-placement.md](fb-placement.md)): faults
  owned by a satellite FB, persisted signals written there, io / eth endpoints in a satellite,
  live DIDs on satellite values; a hand-written satellite (`external = true`) reads nothing
  down. A CM4 doorbell (drain-on-publish) and moving the hand-written xcore seams into shared
  code are follow-ups.
