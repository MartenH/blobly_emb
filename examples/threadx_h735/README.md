# threadx_h735 — ThreadX trace on the STM32H735 (P3c-1, Phase 3)

Phase 3 takes the QEMU foundation ([`threadx_min`](../threadx_min), Phases 1–2) onto
silicon. Same vendored ThreadX kernel, same four TX execution-change hooks
(`trace_hooks.c`, `TX_ENABLE_EXECUTION_CHANGE_NOTIFY`) turning every *real* context
switch and ISR into a blobly 8-byte trace record — now on an STM32H735G-DK at **550 MHz
with true DWT µs timestamps** (QEMU doesn't model `DWT->CYCCNT`, so it fell back to the
10 ms SysTick tick; the board gives real microsecond timing).

What changed from `threadx_min`:

- **`board.c`** (reused from `h735_app`) brings the M7 to 550 MHz on PLL1; `main()` calls
  `board_clock_init()` **before** `tx_kernel_enter`, so the SysTick reload programmed in
  `tx_initialize_low_level.S` (`SYSTEM_CLOCK = 550 MHz`) yields a true 100 Hz tick.
- **`tx_initialize_low_level.S`** — `SYSTEM_CLOCK` 25 MHz → 550 MHz (only change).
- **`threadx_h735.ld`** — same section layout as `threadx.ld`, retargeted to real memory:
  flash 1 MB @ `0x08000000`, DTCM 128 KB @ `0x20000000`.
- **`crt0.S`, `vectors.S`, `trace_hooks.c`** — unchanged. The ThreadX low-level init sets
  `VTOR = _vectors` and reads the initial system stack from it, so the vector table just
  lives first in flash; no board-specific reset glue needed. `trace_hooks.c` reads the
  real `DWT->CYCCNT` and converts with `-DTRACE_CPU_MHZ=550`.

```
make -C ../.. deps      # once: fetch third_party/threadx + CMSIS
make flash              # st-flash the .bin to 0x08000000
make semihost           # openocd: reset+run with semihosting -> prints TRACE_DUMP..TRACE_END
```

`make semihost` runs the flashed image under openocd with semihosting enabled (the dump
uses `bkpt 0xAB` SYS_WRITE0, which needs a debugger to service — standalone it would
HardFault). Expect the banner, then `TRACE_DUMP` followed by hex records and `TRACE_END`.
Decode them the same way as `threadx_min` (kind`<<`14|id | info | start_us(u24) |
cpu_us(u16); kind THREAD=1/ISR=0; reason preempt/block/yield/exit) — here start_us is in
**real microseconds** and the SysTick ISR (id 15) lands on true 10 ms tick boundaries.
blobly_net renders the swimlane from the same records (`manifests/h735-app.csv`).

## Layout

- `main.c` — A/B workers + a C preemptor + a dumper thread; `board_clock_init()` first.
- `trace_hooks.c` — the four `_tx_execution_*` hooks → blobly 8-byte records + semihosting
  dump (copied from `threadx_min`, unchanged).
- `board.c` / `board.h` — 550 MHz clock bring-up (copied from `h735_app`).
- `crt0.S`, `vectors.S`, `tx_initialize_low_level.S`, `threadx_h735.ld` — board bring-up.
- `Makefile` — builds `third_party/threadx` + the demo, flashes, runs under openocd.

Next (Phase 4): the CAN Rx ISR + comm thread, and dumping the ring over FDCAN so the
board runs standalone (no debugger) and blobly_net decodes it live like P3c-0.
