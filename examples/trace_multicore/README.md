# trace_multicore — two-core handler tracing, fully generated (P3a)

Two partitions on two cores (`sense` on core 0, `ctrl` on core 1), each a pure-compute Loom, both
traced. Everything is generated from [`ecu.toml`](ecu.toml) by loom2v — the per-core capture rings,
the single `partition_trace` owner (TraceCmd/TraceRsp + the per-core ISO-TP dump), and CpuLoad. The
only hand-written source is [`main.v`](main.v): open the trace bus channel, hand off to `gen.run(ch)`.

This is the multi-core slice (P3a) of the trace-codegen phase — see
[`docs/trace-multicore.md`](../../docs/trace-multicore.md). It replaces the earlier hand-wired "P4
dev harness" that lived here; nothing is bespoke now.

## Run

```sh
sudo make vcan     # once, bring up vcan0
make run           # generate + build + run on vcan0
```

## What it does

- **core 0 (`sense`)**: `FastSense.on_5ms`, `MedSense.on_10ms` capture into core 0's ring.
- **core 1 (`ctrl`)**: `CtrlWork.on_10ms`, `SlowCtrl.on_20ms` into core 1's ring. `SlowCtrl` glitches
  every 40th run (~20× the work) to blow the trigger budget, so **core 1's ring freezes** on its own
  around the anomaly — independently of core 0.
- A single **`dump` command with core mask `0x0003`** freezes + streams **one self-describing ISO-TP
  block per core** on `0x7E5` (flow control `0x7E6`). Each block leads with a header record (core +
  count), so the two blocks are distinguishable without external framing.

## Watch it

Drive from blobly_net — decodes the fixed protocol natively from the generated manifest
(`gen/trace-manifest.csv`), no DBC:

```sh
# GUI swimlane (per-core handler lanes):
BLOBLY_PROJECT=examples/trace_multicore/trace-multicore.blobnet   # or blobly_net/projects/trace-multicore.blobnet

# headless (both blocks, decoded):
(blobly_net) v -path "@vlib|@vmodules|modules" run cmd/trace_dump/dump.v vcan0 0x0003 \
    ../blobly_emb/examples/trace_multicore/gen/trace-manifest.csv
```

Or raw with can-utils:

```sh
candump vcan0,7E3:7FF &                    # TraceRsp — one per selected core (b7 = core)
cansend vcan0 7E2#03000000FFFF0300         # stop cores 0+1 (freeze the rings)
cansend vcan0 7E2#06000000FFFF0300         # dump cores 0+1 -> two ISO-TP blocks on 0x7E5
```

## Scope (P3a)

FB records only (a polled host loop has no thread/ISR events), one partition per core, no COM bus
bridge. The per-bus **comm thread** becoming visible (P3b) and real **thread/ISR** capture on the
ThreadX target (P3c) are the next slices — see the design doc.
