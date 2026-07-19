# h755_io_analog — analog IN + analog OUT on one board, no pot required

docs/io.md **P2 (ADC) + P3 (PWM)** on the NUCLEO-H755ZI-Q (CM7). Two analog
points as ordinary signals, benchable with **nothing but a scope and a jumper**
— the H755 Nucleo has no onboard potentiometer, so the demo does not need one.

## What it does

- **PWM out (P3) — `FanDuty` on PE9 (TIM1_CH1).** The `Sweep` FB **self-ramps**
  the duty as a triangle, 0→100 %→0 over ~4 s, from its own 10 ms tick count. The
  carrier is 20 kHz (50 µs period). No input hardware needed — the scope trace
  sweeps on its own.
- **ADC in (P2) — `Pot` on PA3 (Arduino A0).** Free-running continuous scan +
  circular DMA. The raw 12-bit count is published on the bus as **`PotLevel`
  (`PotState` 0x311, cyclic 100 ms)** and lights **LD1 green (PB0)** past
  mid-scale (≥ 2048).

## Bench recipe

```sh
make -C ../.. deps          # once: ThreadX + CMSIS
make gen && make            # build/h755_io_analog.bin, linked at 0x08000000
make flash                  # st-flash write + reset  (add --serial for a specific board)
candump can0                # PotState 0x311 @ 100 ms, CpuLoad 0x7E0 @ 1 s
```

- **Scope PE9** → the duty sweeps 0..100 %..0, ~4 s period, 20 kHz carrier. (P3)
- **PotState 0x311** → the live ADC count. Floating PA3 jitters (converter
  alive); jumper PA3 to **3V3** → ~4095 + LD1 on; to **GND** → ~0. (P2)

The two paths are independent: the PWM proves itself on the scope with nothing
wired; one jumper on PA3 proves the whole ADC + DMA + publish chain.

## On-target regression test

`bench_test.sh` is an **automated** version of the checks above — no scope, no
jumper, no eyes on the board. With the H755 attached it flashes this image and
reads TIM1 / ADC1 / DMA1 and the io-thread liveness counter over SWD, asserting
11 things: the PWM carrier + MOE + duty→CCR chain (REQ-IO-021), the ADC scan +
DMA producing samples (REQ-IO-018), and the io serve loop still advancing — the
regression guard for the pacing-sleep wedge (REQ-IO-024).

```sh
./bench_test.sh --flash      # flash + assert; exit 0 pass / 1 fail / 2 no-board
make -C ../.. hwtest         # the whole on-target test group (all bench_test.sh)
BLOB_HWTEST=1 make -C ../.. trace   # record the pass into the h755/target column
```

It is the first member of the on-target test group; a normal `make trace` (or CI
with no board) skips it, so it never fakes a pass or a fail.
