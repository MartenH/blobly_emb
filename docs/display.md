# Display — a local screen on a node

The H735-DK carries a 4.3" 480×272 touch LCD. With `[display]` in its `ecu.toml`, a ThreadX node
drives it from **one more thread** that owns the LCD, the touch panel and the graphics library
([LVGL](https://lvgl.io), v9.6.0). This is the "HMI" of the system node (docs/multi-node.md, P4).
`examples/system_full/nodes/sysnode` is the first node with one.

```toml
[display]
ui = "display_ui.c"   # the node's screen: ui_create() and ui_update(), C, beside its ecu.toml
```

```
make -C <repo> deps-lvgl     # once: LVGL is optional in `make deps`; about 33 MB, sparse and pinned
make flash                   # in the node's directory, as before
```

## How it fits

| piece | where | does |
|---|---|---|
| the thread | generated (`tools/loom2v/gen_display.v`) | `display_thread_create(prio)` in `tx_application_define`, at a priority **below every other thread** of the image, the DoIP threads included |
| the platform | `boards/h735dk/display.c` | LVGL, the double buffering, touch polling; calls the node's `ui_create` once and `ui_update` every pass (at most 20 ms apart) |
| the drivers | `boards/h735dk/lcd.c`, `touch.c`, `hyperram.c` | the LTDC, the FT5336/GT911 touch controller over I2C4, the 16 MB HyperRAM on OCTOSPI2: register-level, no HAL, pins and timings from ST's `stm32h735g-dk-bsp` |
| the build | `boards/h735dk/display.mk`, included by `gen/loom_build.mk` | LVGL as a pinned archive (`-O2`), the sources above, the node's `ui` file, as `LOOM_DISPLAY_SRCS` and `LOOM_DISPLAY_DEFS`. Only an image with `[display]` gets them, and only the Makefiles of a board with a `display.mk` (today the H735-DK's) list them |
| the screen | the node (`ui = …`) | hand-written C against LVGL's API |

**Only the display thread calls LVGL.** It reads what the node already publishes: single-writer
words and read-only registers. sysnode's screen has three tabs:
- **Overview:** uptime, the whole core's CPU, and the display's frame rate.
- **Threads:** every ThreadX thread with its priority and last-second CPU, busiest first, plus the
  interrupts.
- **Buses:** both FDCANs' state and error counters, and the Ethernet link and DoIP state.

Along the bottom of every tab runs an **LED chaser strip**: two rows of dots with a comet hopping
one dot per tick at 10 Hz, compute → edge on top and edge → compute below. Motion meant to be
discrete reads well at 10 Hz, where a gliding one stutters.

**Signals are the next step.** The IOC channels are single-reader, so a signal reaches the display
through a channel of its own, allocated by loom2v.

**CPU is sampled** (`boards/h735dk/cpuprof.c`). TIM7 interrupts ~9973 times a second, at the
highest priority, and records what the core was doing at that instant:
- **a thread:** ThreadX's current-thread pointer says which one;
- **an interrupt:** the interrupted handler's own exception number (in its stacked xPSR) says so;
- **idle:** ThreadX's idle wait, which on this port spins inside PendSV with no current thread.

The rate is deliberately not a multiple of the 1 kHz tick, so periodic work cannot alias with it.
Over a second that is ~10 000 samples, which gives each thread's share to about 0.01% at about 0.1%
CPU overhead. The display thread differences the counters once a second into `display_cpu_pm`
(the whole core) and `display_loads()` (per thread).
- **Why not the Loom load cells:** they measure FB handler time only. On a gateway, whose work is
  in its comm, network and display threads, they read about 0%.
- **Why not ThreadX's own hooks:** `TX_ENABLE_EXECUTION_CHANGE_NOTIFY` belongs to the trace
  recorder (`trace_hooks.c`). `TX_LOW_POWER` needs the kernel rebuilt, and its `WFI` sleep stops
  the DWT counter `board_now_us` runs on.
- **TIM7** is the profiler's (the io PWM map uses TIM1/TIM2). `weak_irq.c` gives its vector an
  empty default in every image without a display.

**Which board can drive a display is the board's to say.** loom2v does not know the part. The
generated build includes `boards/$(BOARD)/display.mk`, and a board without one stops the build with
`[display]: board … has no display`.

**Refused for now:**
- **With `[trace]`:** the display thread is not yet in the trace manifest, which fixes every
  thread's id and caps their number. Nothing deeper conflicts, since the profiler does not use the
  trace hooks. Adding a manifest row and a `trace_bind_thread` call is the follow-up.
- **On a non-ThreadX target**, and **on a node with a satellite image**.

## Memory

| what | where | why |
|---|---|---|
| two framebuffers, 255 KB each | HyperRAM, 0x70000000 / 0x70040000 | double buffering; the AXI SRAM holds one at most |
| the thread's stack (16 KB) and LVGL's pool (64 KB) | AXI SRAM, `.axisram` (`threadx.ld`) | out of the DTCM the real-time threads use. The pool is a fixed static array LVGL allocates from itself, owned by the one display thread: the bounded-pool exception in docs/no-alloc.md, not a heap |
| LVGL code and fonts | flash, about 360 KB | sysnode went from 87 KB to 448 KB of its ~894 KB app slot |

If the HyperRAM fails its self-test at start, the display thread leaves the panel off and reports
`display_state = DISPLAY_NO_RAM`. The rest of the node runs unaffected.

## Double buffering

LVGL draws (in DIRECT mode) into the buffer not on screen. The frame's last flush points the LTDC
at it **at the next vertical blanking** (`lcd_show`, an LTDC vertical-blanking reload), and LVGL is
released only once that switch has happened. LVGL then copies the frame's dirty areas into the
other buffer itself. The wait sleeps, so it is not counted as CPU. With one buffer the panel
visibly tore, because LVGL drew into the buffer being scanned out.

## What it costs (measured on the bench, 2026-10-06)

The figures below are the display thread's share from a demonstrator screen: an animated speed
gauge redrawn at up to 50 fps, averaged over a 20 s cycle. They were read over SWD as
`display_load_pm`, the wall time of the thread's passes less the swap wait. That figure includes
any time the thread spent preempted, so it is an upper bound; on the idle bus it was measured on,
the two agree.

| configuration | CPU avg / peak |
|---|---|
| double buffered in HyperRAM, LVGL `-O2` (**as built**) | 26.5% / 33.5% |
| one framebuffer in AXI SRAM, LVGL `-O2` (tears) | 18.7% / 26% |
| one framebuffer, LVGL `-Os` | 21.5% / 29% |

- **Where the cost is:** almost all of it is software rendering of what changes. A moving needle
  invalidates most of a gauge, so the gauge is redrawn every frame.
- **Double buffering's cost:** about 8 points. The two configurations differ in both buffer count
  and memory (two in HyperRAM against one in AXI SRAM), so the cost is not split between them. Two
  things contribute: each frame's dirty areas are copied into the other buffer (a HyperRAM read and
  write), and HyperRAM writes are about 7× slower than on-chip ones (the table below).
- **Frame rate:** the refresh is capped at **30 fps** (`LV_DEF_REFR_PERIOD` 33 ms).
- **sysnode on the Overview tab, chaser strip running:** the whole core reads **7.6%** at about
  12 fps, with no bus traffic.
- **Large animated backgrounds are expensive:** three drifting circles behind the cards cost 51%
  (71% peak) at 30 fps, because everything they cross is re-blended every frame.
- **A full-face gauge redrawn continuously** (a needle sweeping at 30 fps, tried on sysnode and
  removed) cost the whole core 19%, peaking at 21%, at 27.5 fps.

## DMA2D: measured, not used

LVGL's DMA2D draw backend (`LV_USE_DRAW_DMA2D`, register-level, no HAL) was tried on sysnode on
2026-10-06 and left off (`lv_conf.h` says why). It worked: the DMA2D's registers showed LVGL's
plain fills going through it. But a full-screen redraw took **14.9 ms against 14.8 ms** without it,
and the steady load stayed at 7.5%.

Bandwidth, measured on the board (64 KiB each, **D-cache off**, as on this board — board.c):

| | HyperRAM | on-chip AXI SRAM |
|---|---|---|
| DMA2D fill (write) | 174 MB/s | 549 MB/s |
| CPU write | 159 MB/s | 1080 MB/s |
| CPU read, 16 bits at a time (as a blend reads) | 81 MB/s | 84 MB/s |

- **The read row is CPU-bound** (about 13 cycles a load for both). It shows only that HyperRAM reads
  keep up with a pixel-by-pixel blend loop, not what either memory can deliver.
- **Rendering is CPU-bound, not memory-bound.** A whole-screen write is about 1.5 ms of the 14.8.
- **The rest is CPU rendering DMA2D cannot take:** anti-aliased text, rounded corners, circles,
  lines. The draw backend takes only plain, unrounded, ungradiented rectangles and image copies,
  a small share of this UI.
- **No CPU freed:** with `LV_OS_NONE` LVGL waits for each transfer, so even the fills it takes free
  nothing.

**The lever left:** the double-buffer **sync copy**. In DIRECT mode with two buffers, LVGL copies
each frame's dirty areas into the other buffer with the CPU (`lv_draw_buf_copy`), unless the
display has a `sync_cb`. A `sync_cb` could hand that copy to the DMA2D (memory-to-memory),
independent of the draw backend and of `LV_USE_OS`. It is not worth it for the steady screen,
where the copy is the strip (about 21 KB a frame). It is worth it for a UI that changes large areas
every frame.

**When to revisit the draw backend:** a UI made of large plain rectangles or images. An OS
integration (`LV_USE_OS`) would let transfers overlap rendering, but it is not a free switch: LVGL
then starts its own render threads (`lv_draw_sw.c`). That breaks the one-display-thread design, the
LVGL pool's "owned by one thread" basis (docs/no-alloc.md), and the trace manifest's fixed thread
ids.

**Interrupt caveat:** enabling the backend enables `DMA2D_IRQn` in the NVIC, which this board's
vector table routes to `__tx_BadHandler` (IRQ90).
- `LV_USE_DRAW_DMA2D_INTERRUPT 1` sets the transfer-complete interrupt (`DMA2D_CR_TCIE`) **even
  under `LV_OS_NONE`**, despite LVGL's own "no effect" warning. That combination hangs the node on
  the first transfer.
- Any setting of that flag to 1 needs a `DMA2D_IRQHandler` in the vector table first.

## Bench notes

- **One animated object, not many:** LVGL tracks at most 32 dirty areas per frame
  (`LV_INV_BUF_SIZE`); past that it redraws the **whole screen**.
  - The chaser strip first changed 92 dot objects per tick, and cost 30% of the core.
  - As one object that draws its own dots (`LV_EVENT_DRAW_MAIN`, one dirty area per tick) it costs
    a quarter of that.
  - The profile pointed straight at it: 42% of the display thread's samples were in
    `lv_draw_sw_blend_color_to_rgb565`, LVGL filling full-screen rectangles in software.

- **Theme:** use a light one (dark text on white). The panel's contrast and viewing angle make
  light text on a dark background hard to read, and LVGL's default theme gives a card's labels
  dark text, which vanished on dark cards.

- **HyperRAM clock:** OCTOSPI2 is clocked from HCLK3 / 3 = 91.7 MHz. ST's BSP uses PLL2, which is
  this board's FDCAN clock.
- **HyperRAM delay block:** the OCTOSPI delay block must stay in the read path. Bypassed, every
  odd byte read back with bits stuck at 1.
- **Touch, idle reports:** this board's touch controller is an FT5336. When idle it reports 0xFF
  in every byte, so a finger count past 5 means "no touch", as ST's driver reads it.
- **Touch, axes:** the FT5336's axes are swapped against the panel (its X is the panel's Y), with
  no mirroring.
- **Touch, other revisions:** a GT911 board revision is read unswapped and is untested.
- **Clocks:** the LCD pixel clock is PLL3_R = 9.64 MHz (PLL3 was unused).
- **Pins:** the LCD's 28 pins are on ports A–H, and none is shared with FDCAN1/2, RMII or SWD.
