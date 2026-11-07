# xcore — the cross-core coordination layer

> **Naming note.** This subsystem was called `duo` (a cute "two cores" tag). It is being renamed
> to **`xcore`** — cross-core, matching `xioc` (the cross-core IOC channel, which lives *under*
> xcore). Where this doc says `xcore_*` / `XCORE_*` / `xcore.h`, the tree may still say `duo_*` /
> `DUO_*` / `duo.h` until the mechanical rename lands; the design is what's described here.

xcore is everything two cores need to cooperate on an **AMP** part (one chip, independent kernels
per core — e.g. the STM32H755's Cortex-M7 "owner" + Cortex-M4 "satellite"). It is *not* a message
bus: it is a fixed shared-memory map plus three boot handshakes, and on top of those a small set of
single-writer/single-reader primitives (signals, bulk, trace, load). One generator run
(`ecu.toml` → loom2v) emits **both** images, so the two sides are matched by construction.

The whole layer lives in one reachable-by-both, **uncached** region: the H755's D3 **SRAM4**
(`0x38000000`, 64 KB). D-caches are off by policy, so plain `volatile` accesses are coherent with
no cache maintenance — see [multicore-perf.md](multicore-perf.md) for why (and why it costs the
bulk path nothing: the payload must be non-cacheable regardless).

## The shared window (SRAM4 map)

`boards/h755zi/xcore.h` is the one source of the layout — one header, two consumers. Nothing here
is claimed by either core's linker.

| offset | region | writer → reader | purpose |
|-------:|--------|-----------------|---------|
| `+0x000` | heartbeat (`CM4R` + counter) | sat → owner | liveness |
| `+0x008` | clocks-ready (`CLKR`) | owner → sat | release the parked satellite (handshake #1) |
| `+0x010` | layout **REQ** (owner boot nonce) | owner → sat | matched-images handshake #2 |
| `+0x014` | layout **ACK** (`req ^ LAYOUT_ID`) | sat → owner | " |
| `+0x018` | satellite boot **epoch** (retained, ++ per boot) | sat → sat | restart-unique sequence seeds |
| `+0x020` | IOC pool `xioc_t[N]` | sat → owner | cross-core **signals** (the {a,b} pair cell) |
| `+0x200` | trace handoff cell + records | both | two-core **trace** dump |
| `+0xC00` | bench burst flag + **load** slots (`u16[8]`) | mixed | bulkperf trigger; per-core **CpuLoad** |
| `+0xC20` | **busy** slots (`u32[8]`: share, publish count) | sat → owner | each core's total load, for `ps` |
| `+0x1000` | wide-signal window (`XW`, 4 KB) | sat → owner | **wide** signals (>2 fields, or a field not `u32`) |
| `+0x2000` | **bulk** window (52 KB, to the owner window) | producer → consumer | zero-copy **blocks** |
| `+0xF000` | owner **ACK** (`ack(nonce ^ LAYOUT_ID)`, 0 = retracted) | owner → sat | matched-images handshake #3 |
| `+0xF004` | owner boot **nonce** (retained, odd, new per boot) | owner → sat | " |
| `+0xF020` | owner-written window (`OW`, to top of SRAM4) | owner → sat | **down** signals (owner → satellite) |

One HSEM semaphore (sem 0) is the bulk **doorbell**: the producing core releases it → IRQ125
(HSEM1) on the owner → its comm thread drains the pool on publish instead of polling.

## Three handshakes

All three exist because **SRAM4 is retained across resets** — a naive shared cell can carry a previous
boot's value into the next one.

**#1 Clocks-ready — releasing the satellite.** On the H755 only the owner brings up the PLL. The
satellite parks in `xcore_wait_clocks()` until the owner writes `CLKR` (after `board_clock_init`),
so the satellite's SysTick is set against the *final* HCLK, never the 64 MHz boot clock. The owner
emits this from its generated `boot()` whenever it owns a satellite — so a shared `main.v` (a
system_full node) releases its satellite without hand-written glue.
*Known limit:* the `CLKR` marker is a retained level flag, so a **both-core** reset can let the
satellite leave the wait before the owner re-runs `board_clock_init`. That is the warm-reset
problem (see Boundaries).

**#2 Layout REQ/ACK — matched images.** Two SPSC cells, one writer each (a single shared cell had
both cores writing it — a real bug). The owner bumps a **retained boot nonce** (REQ) at boot,
invalidating every prior acknowledgement. The satellite, after initializing its channels, writes
`ACK = REQ ^ XCORE_LAYOUT_ID`, where `LAYOUT_ID` is an FNV-1a hash of the *whole* slot/offset/schema
map (generated into `xcore_gen.h`). The owner trusts no cross-core read until `ACK` matches. A
stale or differently-built satellite therefore reads as **never-fresh**, never as slot cross-talk
(signal A's bytes surfacing as signal B). The satellite zeroes ACK first thing at boot, so polling
stops while it re-inits.

**#3 Owner ACK — the down direction.** The same gate, mirrored, for what the owner writes. The
owner's generated `boot()` retracts its ACK, bumps its own **retained odd nonce**, initialises every
owner → satellite channel with a sequence seed derived from that nonce, and only then commits
`ACK = ack(nonce ^ XCORE_LAYOUT_ID)` — all before it releases the satellite's clocks, which it does
last, once every restore (a parameter's among them) has published (`boards/h755zi/xcore_owner.c`). The satellite's reader checks the ACK on **every read**: a
retracted or mismatched ACK reads as the port default, and a changed owner nonce resets the
reader to the default, so a new owner boot never shows the previous boot's value. A boot manager
that stays for programming retracts this ACK too (`boot_park_satellite`).

## The primitives

- **Signals (`xioc`).** Plain-store, sequence-stamped slots (`boards/common/xioc.h`): the writer
  stamps a sequence, writes the payload, re-stamps; the reader retries on a torn stamp. `ioc.h`'s
  exchange-based triple buffer is **not** cross-core safe on this fabric (LDREX/STREX doesn't
  arbitrate across cores here — 162/200k torn reads measured before this design). The direction
  comes from where the FBs sit, never from config: a signal **produced on a satellite** derives an
  up slot — the satellite publishes via `xcore_pub`, the owner reads via `xcore_poll` (the pool
  holds `XCORE_IOC_N` = 4 pair slots; a fifth is a build error in `xcore_gen.h`); a signal
  **produced on the owner** (an owner FB's output, or a frame the comm thread receives) that a
  satellite FB **reads** derives a down channel in the `OW` window. Readers come from the FBs'
  `reads`, not the signal's `to`, so an owner FB and a satellite FB may read one signal — its one
  writer feeds both.
- **Wide signals (`xioc_n`).** Signals past the {a,b} pair — 3+ fields, or any field not `u32` —
  ride size-proportional channels in the `XW` window; per-signal offsets are generated and
  static-checked against the budget. Same plain-store discipline; a mismatched writer reads as
  never-fresh (the layout handshake again). Every down channel is an `xioc_n` channel.
  A field takes one u32 **lane** (`bool`/`u8`/`u16`/`u32`/`i8`/`i16`/`i32`/`f32`; signed as two's
  complement, `f32` by its bits) or two (`u64`/`i64`/`f64`, low word first); a channel carries
  1..16 lanes and is copied whole under its sequence stamp, so a 64-bit field never tears. The
  reader state lives in the reading thread's own state struct, so any number of reader threads is
  safe (the owner reads a wide up signal the same way).
- **Down writers.** A received signal is written by the comm thread: a lean frame as one lane
  (the value field), a checked frame (deadline, E2E, SecOC, `status`/`lost`, several read signals,
  a non-trivial layout, a fault source) as every field including its `RxStatus`, on receipt and on
  timeout. An owner FB's output is written by that FB's thread. The owner allocates its IOC and
  byte-IOC cells only for owner readers.
- **Bulk.** A `[[bulk]]` whose producer and consumer sit on different cores places its SPSC pool
  (`boards/common/bulk.h`) in the bulk window instead of a per-image arena, so both images address
  the same bytes via the `xcore_bulk_base()` seam (glue-provided, never `#include`d by generated
  code). Ownership transfer, fallible counted loans, HSEM doorbell. ~33 MB/s cross-core on the
  H755 at 256 B blocks (the CM4's uncached D2→D3 store bandwidth is the wall, not the ring). See
  [bulk-transport.md](bulk-transport.md).
- **Trace.** A two-core dump handshake: the owner posts arm/snapshot requests in the trace cell,
  the satellite's loop services them and acks with a mid-exchange `svc_us` stamp so the two cores'
  independently-clocked records land on one timeline (the measured offset + error bound). See
  [trace-multicore.md](trace-multicore.md).
- **CpuLoad.** Each satellite publishes its per-mille scheduler load into its load slot every tick;
  the owner reads the satellite slots into the CpuLoad frame, so telemetry reports **every core**,
  not just the owner's. The owner zeroes the slots before releasing the satellite, so an absent
  core reads 0 rather than retained garbage.
- **Busy share.** CpuLoad counts the scheduler's handlers; the busy share is the whole core —
  every thread and every ISR that calls the hooks (SysTick, the FDCAN receive interrupts, the H755
  examples' bulk doorbell), added up by ThreadX's execution-change hooks
  (`boards/common/trace_hooks.c`) over a 1 s window.
  The owner's comm thread closes its window each pass, a satellite's first thread each tick and
  publishes its share into its busy slot with a publish count (`xcore_busy_pub`). The owner sets
  every slot to not measured before releasing the satellite and, each time its own window closes,
  takes a core whose count did not move as not reporting, so a core that never reports or stops
  prints as not measured rather than as its last share. The shell's `ps` prints this core's busy
  and ISR shares over the window it measured, each reporting satellite's busy share, and per thread
  its share (a thread past the recorder's 8 ids is in the total, not broken out). An ISR that does
  not call the hooks is charged to the thread it interrupted.

## How the generator wires it

`has_satellite(m)` (any `[[partition]]` with `image = <dir>`) drives everything: loom2v emits the
satellite image, the owner's `boot()` release call (preceded, when there is a down channel, by
the owner-window bring-up of handshake #3), and the `xcore_gen.h` contract (`LAYOUT_ID` + the slot
map, the down channels' `XCORE_OW_*` offsets included) — the last is written for **every** satellite owner, even a bulk/CpuLoad-only node
with no cross-core signal, because the boot handshake needs `LAYOUT_ID`. The glue C provides the
board seams (`xcore_bulk_base`, `xcore_clocks_ready`, the strong `xcore_load_get/pub`); generated
code never includes the board header. The owner → satellite seams are shared board C instead
(`boards/h755zi/xcore_owner.c` / `xcore_sat.c`, the board's `BOARD_XCORE_OWNER` /
`BOARD_XCORE_SAT`), linked through the image's `gen/loom_build.mk` (`LOOM_GLUE_SRCS`) when its
generated code declares them. See [multi-image.md](multi-image.md).

## Boundaries and known limits

- **Matched images only.** Both images come from one generator run; the REQ/ACK handshake is
  defense-in-depth, not a cross-build compatibility layer. Cross-build skew is *out of contract*.
- **Warm reset is not (yet) safe.** Because SRAM4 is retained, a satellite-only reset (or a
  both-core reset where the satellite boots ahead of the owner) leaves stale state — the pool
  cursors, the `CLKR` flag — that a naive restart would trust. The **decided policy** is that a
  satellite reset takes the whole system down (a system reset of *both* cores), not in-place
  recovery. The mechanism — a restart-unique clock request/ack mirroring the layout REQ/ACK nonce,
  and quiescing bulk before re-init — is tracked under ROADMAP *Fault handling & shutdown*, not
  built. Until then, do not rely on a lone core restarting cleanly beside a live one. The
  owner-written window is the exception: its reader is gated on the owner ACK and resets on a new
  owner nonce (handshake #3), so a down signal reads as the default across an owner reboot, never
  as the previous boot's value.
- **Platform telemetry uses raw slots, not IOC channels.** The heartbeat, clocks-ready, epoch,
  trace `svc_us`, and CpuLoad are single-writer/single-reader `volatile` cells, deliberately *not*
  routed through an `xioc`/OSAL channel. They are platform plumbing, not application signal data
  crossing a partition boundary — the same call as "bulk is not routed through IOC"
  ([memory-protection.md](memory-protection.md) draws the line). Application data crossing cores
  goes through `xioc`/bulk; platform state uses the map.
- **One owner, N satellites.** The map assumes a single owner core arbitrating. No channel runs
  satellite to satellite: a value reaches another satellite only through an owner FB that reads it
  and writes a signal of its own, which goes down.
