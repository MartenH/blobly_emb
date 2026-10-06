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
| the build | `boards/h735dk/display.mk`, included by `gen/loom_build.mk` | LVGL as a pinned archive (`-O2`), the sources above, the node's `ui` file, as `LOOM_DISPLAY_SRCS` and `LOOM_DISPLAY_DEFS`. Both are defined empty on every other ThreadX image, and every ThreadX Makefile lists them |
| the screen | the node (`ui = …`) | hand-written C against LVGL's API |

**Only the display thread calls LVGL.** It reads what the node already publishes: single-writer
words and read-only registers. sysnode's screen shows uptime, the whole core's CPU, both FDCANs'
state and error counters, and the Ethernet link and DoIP state.

**The whole core's CPU** (`display_cpu_pm`) is measured from below. `display_thread_create` also
starts an idle thread at priority 31, which runs only when no thread and no interrupt wants the
core. It counts the cycles of its own loop steps; a step much longer than usual was preempted, and
that time is not counted. CPU is 100% minus what it counted.
- **Why not the Loom load cells:** they measure FB handler time only. On a gateway, whose work is
  in its comm, network and display threads, they read about 0%.
- **Why not ThreadX's idle hooks:** `TX_LOW_POWER` needs the kernel rebuilt with a define, and the
  `WFI` sleep it is for stops the DWT cycle counter `board_now_us` runs on.
- **Cost:** none in power. ThreadX's idle loop spins on this port anyway. **Signals**
are the next step: the IOC channels are single-reader, so a signal reaches the display through a
channel of its own, allocated by loom2v.

**Which board can drive a display is the board's to say.** loom2v does not know the part. The
generated build includes `boards/$(BOARD)/display.mk`, and a board without one stops the build with
`[display]: board … has no display`.

**Refused for now:** `[display]` with `[trace]` (the display thread is not in the trace manifest),
on a non-ThreadX target, and on a node with a satellite image.

## Memory

| what | where | why |
|---|---|---|
| two framebuffers, 255 KB each | HyperRAM, 0x70000000 / 0x70040000 | double buffering; the AXI SRAM holds one at most |
| the thread's stack (16 KB) and LVGL's pool (64 KB) | AXI SRAM, `.axisram` (`threadx.ld`) | out of the DTCM the real-time threads use. The pool is a fixed static array LVGL allocates from itself, owned by the one display thread: the bounded-pool exception in docs/no-alloc.md, not a heap |
| LVGL code and fonts | flash, about 360 KB | sysnode went from 87 KB to 444 KB of its ~894 KB app slot |

If the HyperRAM fails its self-test at start, the display thread leaves the panel off and reports
`display_state = DISPLAY_NO_RAM`. The rest of the node runs unaffected.

## Double buffering

LVGL draws (in DIRECT mode) into the buffer not on screen. The frame's last flush points the LTDC
at it **at the next vertical blanking** (`lcd_show`, an LTDC vertical-blanking reload), and LVGL is
released only once that switch has happened. LVGL then copies the frame's dirty areas into the
other buffer itself. The wait sleeps, so it is not counted as CPU. With one buffer the panel
visibly tore, because LVGL drew into the buffer being scanned out.

## What it costs (measured on the bench, 2026-10-06)

All figures are the display thread's own CPU (`display_load_pm`, `display_fps`, read over SWD).
The measurements were taken with a demonstrator screen, an animated speed gauge redrawn at up to
50 fps, averaged over a 20 s cycle:

| configuration | CPU avg / peak |
|---|---|
| double buffered in HyperRAM, LVGL `-O2` (**as built**) | 26.5% / 33.5% |
| one framebuffer in AXI SRAM, LVGL `-O2` (tears) | 18.7% / 26% |
| one framebuffer, LVGL `-Os` | 21.5% / 29% |

- **Where the cost is:** almost all of it is software rendering of what changes. A moving needle
  invalidates most of a gauge, so the gauge is redrawn every frame.
- **Double buffering's cost:** about 8 points. LVGL draws into uncached external memory, then
  copies each frame's dirty areas into the other buffer.
- **Untried levers:** a lower frame-rate cap, or LVGL's DMA2D backend (`LV_USE_DRAW_DMA2D`, which is
  register-level and needs no HAL).
- **sysnode's status screen:** the display thread takes **4.8%** and the whole core reads **5.9%**,
  with no bus traffic. Nothing on the screen moves faster than once a second.

## Bench notes

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
