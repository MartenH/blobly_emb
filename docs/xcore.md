# xcore — the cross-core coordination layer

> **Naming note.** This subsystem was called `duo` (a cute "two cores" tag). It is being renamed
> to **`xcore`** — cross-core, matching `xioc` (the cross-core IOC channel, which lives *under*
> xcore). Where this doc says `xcore_*` / `XCORE_*` / `xcore.h`, the tree may still say `duo_*` /
> `DUO_*` / `duo.h` until the mechanical rename lands; the design is what's described here.

xcore is everything two cores need to cooperate on an **AMP** part (one chip, independent kernels
per core — e.g. the STM32H755's Cortex-M7 "owner" + Cortex-M4 "satellite"). It is *not* a message
bus: it is a fixed shared-memory map plus two boot handshakes, and on top of those a small set of
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
| `+0x1000` | wide-signal window (`XW`, 4 KB) | sat → owner | **wide** signals (>2 fields / sub-u32) |
| `+0x2000` | **bulk** window (56 KB, to top of SRAM4) | producer → consumer | zero-copy **blocks** |

One HSEM semaphore (sem 0) is the bulk **doorbell**: the producing core releases it → IRQ125
(HSEM1) on the owner → its comm thread drains the pool on publish instead of polling.

## Two handshakes

Both exist because **SRAM4 is retained across resets** — a naive shared cell can carry a previous
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

## The primitives

- **Signals (`xioc`).** Plain-store, sequence-stamped slots (`boards/common/xioc.h`): the writer
  stamps a sequence, writes the payload, re-stamps; the reader retries on a torn stamp. `ioc.h`'s
  exchange-based triple buffer is **not** cross-core safe on this fabric (LDREX/STREX doesn't
  arbitrate across cores here — 162/200k torn reads measured before this design). A `from = <sat>`
  signal derives a slot; the satellite publishes via `xcore_pub`, the owner reads via `xcore_poll`.
- **Wide signals (`xioc_n`).** Signals past the {a,b} pair — 3+ fields, sub-u32 types, or a
  `valid` flag — ride size-proportional channels in the `XW` window; per-signal offsets are
  generated and static-checked against the budget. Same plain-store discipline; a mismatched
  writer reads as never-fresh (the layout handshake again).
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

## How the generator wires it

`has_satellite(m)` (any `[[partition]]` with `image = <dir>`) drives everything: loom2v emits the
satellite image, the owner's `boot()` release call, and the `xcore_gen.h` contract (`LAYOUT_ID` +
the slot map) — the last is written for **every** satellite owner, even a bulk/CpuLoad-only node
with no cross-core signal, because the boot handshake needs `LAYOUT_ID`. The glue C provides the
board seams (`xcore_bulk_base`, `xcore_clocks_ready`, the strong `xcore_load_get/pub`); generated
code never includes the board header. See [multi-image.md](multi-image.md).

## Boundaries and known limits

- **Matched images only.** Both images come from one generator run; the REQ/ACK handshake is
  defense-in-depth, not a cross-build compatibility layer. Cross-build skew is *out of contract*.
- **Warm reset is not (yet) safe.** Because SRAM4 is retained, a satellite-only reset (or a
  both-core reset where the satellite boots ahead of the owner) leaves stale state — the pool
  cursors, the `CLKR` flag — that a naive restart would trust. The **decided policy** is that a
  satellite reset takes the whole system down (a system reset of *both* cores), not in-place
  recovery. The mechanism — a restart-unique clock request/ack mirroring the layout REQ/ACK nonce,
  and quiescing bulk before re-init — is tracked under ROADMAP *Fault handling & shutdown*, not
  built. Until then, do not rely on a lone core restarting cleanly beside a live one.
- **Platform telemetry uses raw slots, not IOC channels.** The heartbeat, clocks-ready, epoch,
  trace `svc_us`, and CpuLoad are single-writer/single-reader `volatile` cells, deliberately *not*
  routed through an `xioc`/OSAL channel. They are platform plumbing, not application signal data
  crossing a partition boundary — the same call as "bulk is not routed through IOC"
  ([memory-protection.md](memory-protection.md) draws the line). Application data crossing cores
  goes through `xioc`/bulk; platform state uses the map.
- **One owner, N satellites.** The map assumes a single owner core arbitrating; satellite images
  are peers of each other only through the owner.
