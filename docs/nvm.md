# Persistence (NvM) — design

> Status: DESIGN (2026-07-14). Requirements: `requirements/nvm.toml` (draft, deriving
> from SYS-REQ-NVM-001). Nothing is built; this page is the shape to argue with.
> Companion decisions it leans on: the bootloader's flash driver
> ([bootloader.md](bootloader.md) — same `FlashOps`/`flash.c`), NM's coordinated
> sleep ([nm.md](nm.md) — the flush point), the signal model
> ([configuration.md](configuration.md)).

## The one idea: FBs get persistence through SIGNALS, not an API

A signal marked persistent is restored before the application's first activation and
journaled by the platform afterwards. The FB that owns it cannot tell it is
persistent — it reads and writes ports, period:

```toml
[[signal]]
name    = "OdoMeters"
fields  = { m = "u32" }
from    = "app"
to      = "app"
persist = true
```

There is deliberately NO `nvm_read`/`nvm_write` in application code. An API would
break the pure In→Out handler contract and reproduce AUTOSAR's NvM surface
(ReadBlock/WriteBlock/job callbacks/result polling — the same pattern-zoo we refuse
at the port layer, [autosar-comparison.md](autosar-comparison.md)). One pattern:
declare it persistent, use it as a signal.

Explicit "save now" flows (end-of-line calibration, configuration writes) are NOT
FB work — they are the diagnostic path: a writable DID bound to the same storage
(the `[[did]]` machinery exists; binding lands in a later phase).

## Lifecycle

- **Restore**: at boot, the generated thread init seeds each persistent signal's
  cell from storage BEFORE the first dispatch — readers see the stored value from
  activation one. Missing/corrupt record → the signal's declared default (a fresh
  ECU behaves exactly like a config-default ECU).
- **Journal**: on change, rate-limited (`[nvm] min_write_ms`, generous default).
  A 32-byte record append costs microseconds — schedulable on the comm thread's
  idle path without disturbing the bus.
- **Flush**: NM's prepare-to-sleep is the natural quiet point — dirty values are
  written while the system is already quiescing. (Power loss between journal
  points loses AT MOST the newest values, never the store — see the format.)

## Storage format: an append journal over a flash sector pair

```
record (one 32-byte flash word — the program granularity, atomic by construction):
  [block_id u16 | len u16 | seq u32 | data ...20 | crc32 u32]
```

- **Append-only**: a new value is a new record; the mount scan takes the
  highest-seq record with a VALID CRC per block. A power cut mid-append leaves a
  torn record whose CRC fails — it is simply ignored: the previous value wins.
  Power-loss safety falls out of the format, exactly like the boot header's
  valid-mark-last rule.
- **Compaction (= the garbage collection)**: a superseded record is garbage the
  moment a newer seq lands — nothing marks it (flash bits are one-way; tombstones
  buy nothing), mount simply ignores it, and its only cost is sector space. When
  the cursor hits the sector end (or opportunistically at sleep-entry past a fill
  threshold), the latest value of every live block is copied into the partner
  sector with BUMPED seq — the copies strictly outrank the originals — and the old
  sector is erased. Crash mid-copy: mount unions both sectors, highest seq wins,
  consistent. Crash before the erase: full duplicates, copies win, the stale
  sector is detected (full + everywhere-outranked) and erased LAZILY at the next
  quiet point — never at mount, where a seconds-long erase would stall boot.
  Repeated crashes converge (idempotent). No sector headers, no state machine in
  flash: which sector is active is DERIVED from content (erased space + freshest
  records). Wear levels perfectly by construction (alternating erase); a wider
  ring is the linear-life upgrade. Whether the live set fits after compaction is
  a GENERATION-TIME check (the generator knows N) — never a runtime failure.
  Values > 20 bytes span chained records (same block_id/seq, part index in len's
  high bits) — v1 keeps persistent signals small; big blobs are not the target.
- **Wear math** (H7: 128 KB sectors, 10k cycles): 4096 records/sector. Even one
  record per second sustained = one erase per ~68 min ≈ 1.3 years of CONTINUOUS
  max-rate writing per pair — and `min_write_ms` plus on-change gating keeps real
  traffic orders below that. More sectors in the ring = linear life extension.

## Dynamic data without a clean shutdown (position, odometer, hours)

One persistent signal = one block, and a multi-field signal ({x, y, angle}) is ONE
block — its fields restore coherently from one atomic record. Group values that
must survive together into one signal.

For a value that changes continuously on an ECU that may lose power at ANY moment,
the sleep-entry flush is irrelevant — the rate-limited on-change journal is the
mechanism: the loss window is exactly the signal's write interval, so the interval
is a PER-SIGNAL property (`persist_ms = 200`), not just the global default. The
escalation ladder when the window must shrink:

1. **Deadband in the FB** — quantize before writing, so "changed" means
   meaningfully changed (app logic, where it belongs).
2. **Last-gasp write** — the brown-out/PVD interrupt fires while bulk capacitance
   still holds milliseconds; one 32-byte record append costs tens of µs. One ISR,
   one append: exact at every power loss. Fits the format unchanged (a later
   phase, needs board support).
3. **Backend swap** — the engine sees only FlashOps: FRAM/EEPROM (byte-write, no
   wear limit) is a board-level backend for signals that write fast forever, not
   a redesign.
4. **Re-reference on unclean start** — the sleep flush writes a clean-shutdown
   marker record; a mount without one means the last session crashed, and the
   platform can expose that so an FB re-homes instead of trusting a stale value.
   Detection, not prevention — sometimes the correct system answer.

Wear reality check at 5 records/s continuous: ~190 days of NONSTOP writing per
sector pair (duty-cycled to 2 h/day ≈ 6 years); deadbands and per-signal intervals
keep real traffic far below that, and rungs 2/3 exist for the outliers.

## Where it lives in flash (the honest part)

Erasing a sector STALLS same-bank execution (seconds for 128 KB) — the flash map
must be drawn per board, next to the bootloader's:

- **Single-image parts (H735)**: journal in the OTHER bank — H7 read-while-write
  across banks makes erase invisible. Free lunch.
- **H755 with the M4 image in bank 2**: bank 2's tail sectors collide with a live
  M4 fetching from that bank. Options, decided at the board level: compact only at
  NM sleep-entry (the M4 is quiescing too), or run the M4 from RAM (its image is
  ~30 KB — a boot-time copy kills the constraint entirely). Record appends
  (µs-scale) are a non-issue either way; only ERASE needs the quiet point.
- The boards layer owns the sector map (`bootmap.h` precedent); the journal engine
  sees `FlashOps` — the SAME hooks the bootloader defined, and on target the SAME
  `boards/<b>/flash.c` driver. One flash driver, two customers, one bench
  validation.

## Under the hood: blocks, and the signal ↔ journal mechanics

Persistent signals compile down to numbered blocks (generator-assigned ids in a
`nvm_gen.h`-style contract — the duo/io pattern again). `[[nvm.block]]` stays for
NON-signal platform data (diagnostic records later, bootloader metadata if it ever
wants the journal) — owned by platform modules, still never by FBs.

The full path for one signal:

1. **Identity**: the generator walks `persist = true` signals in declaration order
   → block_id 1..N + packed size into the contract table (0/0xFFFF reserved;
   all-0xFF can never parse as a record, so erased flash is self-marking).
2. **Packing**: fields little-endian in declaration order — the wire-encode
   convention, deliberately NOT raw struct memory (stable across compilers and
   firmware updates). Changing a persistent signal's fields changes its packed
   len → stored value reads as corrupt → declared default. Honest rule: edit the
   fields, lose the stored value.
3. **Mount** (boot): scan both sectors; per block keep the highest-seq record with
   a valid CRC into a fixed-size RAM table (generator-dimensioned); the write
   cursor is the first erased word.
4. **Restore**: generated thread init unpacks the table entry into the signal's
   cell BEFORE the first dispatch — a restored value is indistinguishable from a
   computed one.
5. **Write**: the generated wrapper (which already routes every signal write)
   additionally stages the new value into the block's RAM-table slot and marks it
   dirty — a seq-stamped latest-value slot, the xioc pattern, because it is the
   same problem (single writer thread, single journal reader, never block, latest
   wins). The COMM THREAD polls dirty flags on its idle path and appends records,
   rate-limited; the FB thread never touches flash.
6. **Flush/compact**: NM prepare-to-sleep journals all dirty blocks and is the
   designated compaction window where erase would otherwise stall a live core.

## Sim story

The journal engine is pure V over `FlashOps` — unit-tested against RAM (mount,
append, compact, torn-record power-cut fuzz: cut the "flash" at every byte offset
and re-mount), and host examples back it with a file (the boot_sim precedent).
The entire layer develops dry.

## Phasing

1. **P1 — the journal engine** (`nvm/` module): format, mount, append, compact
   over FlashOps; power-cut fuzz tests. Pure host work.
2. **P2 — `persist = true` codegen**: restore-before-dispatch + change-detect +
   rate-limited journal on the comm thread; host sim example (file-backed).
3. **P3 — target**: reuse `boards/h755zi/flash.c`; flash map decision per board;
   NM sleep-entry flush + compaction window. (Bench: pull power mid-append, on a
   loop, and count survivors.)
4. **P4 — DID binding**: writable DIDs backed by blocks (the explicit-write path);
   `[nvm]` policy knobs (per-signal write-through for the rare value that earns it).

## Non-goals (v1)

- Large blobs / file semantics (records are signal-sized; chaining exists but is
  not the design center).
- Cross-core persistent signals (the satellite's persistent state would journal
  through the owner — needs a crossing design; defer until a real M4 use case).
- Redundant dual-copy storage per block (the journal's previous-record fallback
  covers the power-cut case; true redundancy arrives with an ASIL owner).
