# trace_multicore — two-core handler tracing, fully generated (P3a)

> **STATUS: the two-core dump is GENERATED and verified (#270).** A `dump` with core mask `0x0003`
> answers with each core's window as self-describing ISO-TP blocks on `0x7E5`; `sense` (core 0) owns
> the trace bus and the module, `ctrl` (core 1) records into a ring the owner imports. The
> **system-wide freeze** works too: `SlowCtrl`'s glitch on core 1 freezes core 0's ring as well, with
> no host command, so both windows cover the same instant.
>
> Still a P3a slice, so: FB records only (a polled host loop has no thread/ISR events), two cores
> maximum (the module holds one satellite import slot), and no `HandlerStat` fan-out (`push_ms = 0`).
> A command selecting both cores also answers with ONE `TraceRsp` — the owner's; core 1's state
> rides its own dump block header. A per-core response pair would need a response queue.

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
candump vcan0,7E3:7FF &                    # TraceRsp (b7 = core). A both-cores command answers
                                           # ONCE, from the owner; core 1's state rides its block
isotprecv -s 0x7E6 -d 0x7E5 vcan0 &        # ISO-TP receiver: answers each block's FF with flow
                                           # control on 0x7E6 and reassembles 0x7E5 (needs can-isotp)
cansend vcan0 7E2#03000000FFFF0300         # stop cores 0+1 (freeze the rings)
cansend vcan0 7E2#06000000FFFF0300         # dump cores 0+1 -> two ISO-TP blocks on 0x7E5
```

(Without an ISO-TP receiver on `0x7E5`/`0x7E6`, `partition_trace` sends only each block's First
Frame and waits for flow control — nothing reassembles. `cmd/trace_dump` or the GUI do this for you.)

## Scope (P3a)

FB records only (a polled host loop has no thread/ISR events), one partition per core, no COM bus
bridge. The per-bus **comm thread** becoming visible (P3b) and real **thread/ISR** capture on the
ThreadX target (P3c) are the next slices — see the design doc.
