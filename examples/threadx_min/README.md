# threadx_min — ThreadX Cortex-M7 trace (P3c-1, Phases 1-2)

Phase 1 proved the vendored ThreadX kernel builds for Cortex-M7 and schedules
preemptively. Phase 2 wires the four TX execution-change hooks (`trace_hooks.c`, built
with `TX_ENABLE_EXECUTION_CHANGE_NOTIFY`) so every *real* context switch and ISR becomes
a blobly 8-byte trace record in a static ring — the true scheduler boundaries, not a
polled synthesis. The dumper thread emits the ring over semihosting (`TRACE_DUMP` ...
`TRACE_END`) for the host to decode. Next: the STM32H735 (real DWT µs timing) and
loom2v codegen.

```
make -C ../.. deps      # once: fetch third_party/threadx (pinned, gitignored)
make run                # build + run under QEMU mps2-an500
```

Expected: a banner, then `TRACE_DUMP` followed by hex records. Decode them (kind<<14|id |
info | start_us(u24) | cpu_us(u16); kind THREAD=1/ISR=0; reason preempt/block/yield/exit)
to see A/B/C, the dumper, and ThreadX's system timer thread interleaving, preempted by C,
with SysTick ISRs. Timestamps are 10 ms-granular under QEMU (it doesn't model DWT->CYCCNT);
the H735 gives true microsecond timing.

## Layout

- `main.c` — A/B workers + a C preemptor + a dumper thread (ours).
- `trace_hooks.c` — the four `_tx_execution_*` hooks -> blobly 8-byte records + semihosting dump (ours).
- `Makefile` — builds the ThreadX kernel from `third_party/threadx/ports/cortex_m7/gnu`
  + `common/src` into `build/tx.a`, links the demo, runs it under QEMU.
- `crt0.S`, `vectors.S`, `tx_initialize_low_level.S`, `threadx.ld` — board bring-up,
  **copied from** `threadx/ports/cortex_m7/gnu/example_build/` (MIT-licensed ThreadX
  sample). They target QEMU `mps2-an500` (25 MHz core, 100 Hz SysTick); adapting them to
  the H735 (550 MHz, its SysTick + vector table + flash/RAM map) is the next step.

ThreadX itself is not vendored into the repo — `make deps` clones it (pinned) into the
gitignored `third_party/`, same as the CMSIS headers.
