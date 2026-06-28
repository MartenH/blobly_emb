# h735_blinky — bare-metal pipeline proof (STM32H735G-DK)

The smallest possible example whose only job is to prove the **toolchain**:

```
main.v ──V -freestanding──▶ build/blinky.c ──arm-none-eabi-gcc──▶ blinky.elf ──objcopy──▶ blinky.bin ──flash──▶ board
```

No HAL, no CMSIS, no CubeIDE — a hand-written vector table + linker script, and a
few registers poked directly. Once this blinks, the bare-metal **FDCAN** driver
(`driver/can`, register-level) drops in next for a real CAN example on hardware.

This is **not** a blobly app example (no `ecu.toml`/Loom/`gen`): it's a freestanding
firmware, so it has its own self-contained `Makefile` instead of the codegen one.

## Layout

| file | what |
|---|---|
| `main.v` | the V superloop: `init → toggle → delay`, calling three C shims |
| `board.c` / `board.h` | register-level GPIO + delay (no HAL) |
| `startup.c` | Cortex-M7 vector table + reset (copy `.data`, zero `.bss`, call `main`) |
| `linker.ld` | flash @ `0x08000000` (1 MB), DTCM @ `0x20000000` (128 KB) |
| `Makefile` | transpile → cross-compile → `.bin` → flash |

The V `_start` that V normally emits for freestanding Linux is amd64-only and
[now correctly compiles out on non-x86](https://github.com/vlang/v/pull/27564), so
**our** `Reset_Handler` is the entry point — that fix is what makes this build.

## Prerequisites

```sh
sudo apt install gcc-arm-none-eabi binutils-arm-none-eabi   # compiler + newlib
sudo apt install stlink-tools                               # st-flash (or use probe-rs)
```
Plus `v` on `PATH` (vlang ≥ the merge above).

## Build & flash

```sh
make            # build/blinky.bin  (also prints the size)
make flash      # st-flash write build/blinky.bin 0x08000000
make clean
```

The onboard **ST-LINK-V3E** needs no external probe. On **WSL2**, USB doesn't reach
Linux by default: either attach the ST-LINK with `usbipd-win`, or just run `make`
in WSL and flash `build/blinky.bin` from Windows (st-flash / probe-rs / CubeProgrammer CLI).

Expected: **LD1 (green) and LD2 (red) blink together at ~1 Hz**.

## Debugging

We debug the **C** here — the generated `build/blinky.c` plus `board.c`/`startup.c`
(that's where bring-up actually happens; `main.v` is a 3-line loop). V *can* map the
generated C back to `.v` source via `#line` directives — build with `make debug VDBG=-g`
to step the V instead — but for this example the C is the right level.

Install once:
```sh
sudo apt install openocd gdb-arm-none-eabi       # or gdb-multiarch
# VS Code: install the "Cortex-Debug" (marus25.cortex-debug) extension
```

### VS Code (recommended)
A `.vscode/` config is included. Open **`examples/h735_blinky` as the folder**
(File ▸ Open Folder), then press **F5**: it runs `make debug`, flashes over the
onboard ST-LINK-V3E, and stops at `main`. Breakpoints, stepping, and the registers
view work in the GUI. For a peripheral view, drop `STM32H735.svd` (ST CMSIS pack)
in the folder and set `svdFile` in `launch.json`.

### Command line
```sh
make debug          # -Og + DWARF (C-level)
make gdbserver      # terminal 1: OpenOCD gdb server on :3333
make gdb            # terminal 2: connect, load, run to main
```

### WSL2
OpenOCD / gdb / Cortex-Debug all need the probe visible in Linux: attach the
ST-LINK with `usbipd-win` (`usbipd attach --busid <id> --wsl`), or run OpenOCD on
Windows and point Cortex-Debug at it — the same USB caveat as flashing.

## Notes

- **LEDs**: LD1 (green) = `PC2`, LD2 (red) = `PC3`, both on `GPIOC`
  ([UM2679](https://www.st.com/resource/en/user_manual/um2679-discovery-kit-with-stm32h735ig-mcu-stmicroelectronics.pdf)).
  Polarity doesn't matter for a blink — toggling alternates either way.
- **Clock**: runs on the reset default **HSI ~64 MHz** (no PLL setup), so
  `board_delay_ms()` is a calibrated busy-wait — approximate, not a real timebase.
  Tune the multiplier in `board.c` if the blink rate looks off.
- **Warnings**: V's freestanding C emits a few benign warnings (unused builtin
  functions, 64-bit pointer-cast notes). The link is clean — no undefined symbols.
- Verified locally to produce a valid image: initial SP `0x20020000`, reset
  vector into flash with the thumb bit set, fully linked. Flashing/running on
  the board is the user's confirmation step.
