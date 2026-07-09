# threadx_h735 — ThreadX trace on the STM32H735 (P3c-1, Phases 3–4b)

Phase 3 takes the QEMU foundation ([`threadx_min`](../threadx_min), Phases 1–2) onto
silicon. Same vendored ThreadX kernel, same four TX execution-change hooks
(`trace_hooks.c`, `TX_ENABLE_EXECUTION_CHANGE_NOTIFY`) turning every *real* context
switch and ISR into a blobly 8-byte trace record — now on an STM32H735G-DK at **550 MHz
with true DWT µs timestamps** (QEMU doesn't model `DWT->CYCCNT`, so it fell back to the
10 ms SysTick tick; the board gives real microsecond timing). **Phase 4a** makes the
board run standalone by streaming the ring over **FDCAN1** (register-level backend,
`driver/can`) instead of semihosting — see the run section below.

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
make flash              # st-flash the .bin to 0x08000000; the board then runs STANDALONE
candump can0            # watch the trace ring stream out over FDCAN1 on 0x7E5
```

**Phase 4a — dump over FDCAN, no debugger.** The board runs standalone: once the ring
fills, a dumper thread streams it as raw per-record CAN frames (one 8-byte trace record
per classic frame) on `0x7E5`, re-sending the frozen snapshot every ~1 s so a host
`candump` started at any time catches a full copy. Semihosting is gone from the data
path (it needs a debugger to service the `bkpt` and is slow — Phase-3 bring-up only).
Decode the stream on the host:

```
candump -L can0 | grep -oE '7E5#[0-9A-Fa-f]{16}' | sed 's/7E5#//'   # -> hex records
# kind<<14|id | info | start_us(u24) | cpu_us(u16); kind THREAD=1/ISR=0;
# reason preempt/block/yield/exit. start_us is REAL µs; SysTick (ISR id 15) on 10 ms ticks.
```

The dump is paced by the non-blocking `blob_can_tx_ready` back-pressure (REQ-CAN-DRV-007):
the dumper yields (`tx_thread_sleep`) while the Tx FIFO is full instead of spinning, so a
slow bus never wedges the core. blobly_net's live swimlane wants an **ISO-TP** block on
`0x7E5` (`manifests/h735-app.csv`); that arrives in Phase 6 when loom2v generates the V
trace stack onto ThreadX — Phases 4–5 use the raw stream + the host decoder above.

**Phase 4b — FDCAN Rx ISR + comm thread (`comm.c`).** rx is interrupt-driven: the FDCAN1
Rx-FIFO0 "new message" interrupt (vector 35 = 16 + `FDCAN1_IT0_IRQn` 19, routed in
`vectors.S`) wakes a dedicated **comm thread** via a semaphore. The ISR is tiny — it only
clears the flag and posts; the comm thread drains `blob_can_recv` (the driver stays
polled + non-blocking), decodes into an IOC cell (`g_comm_rx`), and does the periodic tx.
Application code never runs in ISR context (the pattern `can_port.h` documents). Both show
up in the trace: the **comm thread by name**, the **Rx ISR as id 35**. The comm thread runs
at the **highest priority** (1) so it preempts the workload/dump and drains the 8-deep Rx
FIFO promptly (the receive-without-loss path). The Rx IRQ shares SysTick's priority (0x40)
so the two never nest — keeping `trace_hooks` single-level (proper nesting is a later
refinement). The dump freezes the ring only while reading it out, then **re-arms**, so it's
a rolling snapshot: CAN activity that arrives after the first dump still appears in the
next one. Verify live:

```
candump can0 &                       # watch 0x7E5 (trace) + 0x7E1 (comm periodic tx)
cansend can0 123#0011223344556677    # -> Rx ISR (id 35) + comm wake appear in the next 0x7E5 snapshot
# 0x7E1 payload = rx_count(u32 LE) | last_rx_id(u16 LE): the count climbs per frame sent.
```

## Layout

- `main.c` — A/B workers + a C preemptor + the comm thread + a dumper; `board_clock_init()`
  + `board_can_clock_pins_init()` + `blob_can_open` first.
- `comm.c` — FDCAN1 Rx-FIFO0 ISR + the comm thread (rx-drain → IOC cell + periodic tx).
- `trace_hooks.c` — the four `_tx_execution_*` hooks → blobly 8-byte records + the FDCAN
  ring dump (`trace_dump_can`, copied from `threadx_min` then retargeted off semihosting).
- `board.c` / `board.h` — 550 MHz clock + FDCAN1 clock/pins (copied from `h735_app`).
- `crt0.S`, `vectors.S`, `tx_initialize_low_level.S`, `threadx_h735.ld` — board bring-up.
- `Makefile` — builds `third_party/threadx` + `driver/can` (FDCAN backend) + the demo,
  flashes, runs standalone.

Next (Phase 4c): back-pressure fixes (event-tx clear-on-send-success, surface the FDCAN
`RXF0S` message-lost flag). Phase 5 morphs A/B/C into the `h735_app` FBs
(Governor/Load/Heartbeat) with a wait-free SRAM IOC; Phase 6 has loom2v generate it all
from `ecu.toml`.
