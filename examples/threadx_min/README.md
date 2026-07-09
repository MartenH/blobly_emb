# threadx_min — ThreadX Cortex-M7 foundation (P3c-1, Phase 1)

The first slice of the real ThreadX target (P3c-1): prove the vendored ThreadX kernel
builds for Cortex-M7 and schedules preemptively, before wiring the execution-change
trace hooks (Phase 2) and moving to the STM32H735.

```
make -C ../.. deps      # once: fetch third_party/threadx (pinned, gitignored)
make run                # build + run under QEMU mps2-an500
```

Expected: a banner, then threads `A` and `B` interleaving (`A B A B A A B A …`) as the
kernel schedules them at their different sleep periods.

## Layout

- `main.c` — 2-thread demo (ours).
- `Makefile` — builds the ThreadX kernel from `third_party/threadx/ports/cortex_m7/gnu`
  + `common/src` into `build/tx.a`, links the demo, runs it under QEMU.
- `crt0.S`, `vectors.S`, `tx_initialize_low_level.S`, `threadx.ld` — board bring-up,
  **copied from** `threadx/ports/cortex_m7/gnu/example_build/` (MIT-licensed ThreadX
  sample). They target QEMU `mps2-an500` (6 MHz core, 100 Hz SysTick); adapting them to
  the H735 (550 MHz, its SysTick + vector table + flash/RAM map) is the next step.

ThreadX itself is not vendored into the repo — `make deps` clones it (pinned) into the
gitignored `third_party/`, same as the CMSIS headers.
