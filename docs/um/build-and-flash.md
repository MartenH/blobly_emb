# How do I build, flash, and talk to the target?

The complete bench recipe for the two-core reference (`examples/h755_threadx` on the
NUCLEO-H755ZI-Q), from a clean checkout to a running node — standalone or behind the
bootloader — plus the blobly_net side (CLI tools and the GUI). Design docs:
[../bootloader.md](../bootloader.md), [../nvm.md](../nvm.md),
[../multi-image.md](../multi-image.md).

## 0. Prerequisites

**Tools** (one-time): the V compiler, `arm-none-eabi-gcc`, `stlink-tools`
(`st-flash`/`st-util`), `openocd`, `can-utils` (`candump`/`cansend`), and
`make -C <repo> deps` once for ThreadX + CMSIS.

**Bench** (every session, WSL): attach the ST-LINK and the CAN adapter, then bring the
SocketCAN interface up:

```sh
usbipd.exe attach --wsl --busid 4-3     # ST-LINK (elevated `usbipd bind` once)
usbipd.exe attach --wsl --busid 2-9     # PCAN-USB Pro FD
sudo ip link set can0 up type can bitrate 500000
sudo ip link set can0 txqueuelen 1000   # default 10 drops ISO-TP bursts (flasher, dumps)
```

The PCAN box silk-screen is 1-indexed: the connector labelled **can1** is SocketCAN
**can0**. Wiring gotchas (transceiver STB, CANH/CANL, VIO) are in the board bring-up
notes; if the wire worked yesterday, suspect the pair first.

## 1. Standalone (no bootloader) — the everyday loop

The app owns the whole flash bank; vectors at 0x08000000. This is the default and what
every other um page assumes.

```sh
cd examples/h755_threadx
make gen        # ecucheck + loom2v (only after ecu.toml / app changes)
make            # build/h755_threadx.bin, linked at 0x08000000
make flash      # st-flash write + reset
candump can0    # NM alive 0x513, Workload 0x200, CpuLoad 0x7E0/0x7E1
                # (0x201 = M4LoadFrame appears only once the CM4 image below runs)
```

The CM4 satellite image is generated into its own example and flashed to bank 2 once
(rebuild/reflash only when the config that feeds it changes — on a fresh or erased
board flash it FIRST, or the two-core checks stay dark):

```sh
make -C ../h755_m4_app
st-flash write ../h755_m4_app/build/h755_m4_app.bin 0x08100000
```

**NvM sectors** (bank-2 tail, 0x081C0000 + 0x081E0000): the journal mounts read-only, so
a board with unknown residue there should get the pair erased once. `st-flash erase`
with a range **mass-erases the whole chip** — don't; use OpenOCD for a targeted erase
(then reflash both images, order doesn't matter):

```sh
openocd -f interface/stlink.cfg -f target/stm32h7x.cfg \
  -c 'init; halt; flash erase_address 0x081C0000 0x40000; reset run; shutdown'
```

## 2. Behind the bootloader — the field layout

Boot manager at sector 0, app at APP_BASE 0x08020000 (64-byte header, vectors at
+0x400). Three artifacts:

```sh
# the boot manager (bare metal, UDS on 0x7B0/0x7B8)
make -C examples/h755_boot

# the SAME app, linked for the app slot — the link mode is part of the artifact:
# switching APP_LINK relinks automatically, and `make APP_LINK=boot flash` refuses
cd examples/h755_threadx && make APP_LINK=boot

# the CM4 satellite (bank 2) — built here too: the factory flash below writes it
make -C ../h755_m4_app

# wrap TWICE — the two images are NOT interchangeable:
#   factory (--valid): pre-marked, for SWD flashing only
#   field  (no mark):  the bootloader itself verifies and writes the mark LAST —
#                      that ordering IS the torn-transfer recovery guarantee
cd ../.. && v run tools/mkimage examples/h755_threadx/build/h755_threadx.bin \
    examples/h755_threadx/build/factory.img <sw_version> --valid --pad-vectors
v run tools/mkimage examples/h755_threadx/build/h755_threadx.bin \
    examples/h755_threadx/build/field.img <sw_version> --pad-vectors --sign examples/keys/mkimage.seed
```

**First time (factory, over SWD):**

```sh
st-flash write examples/h755_boot/build/h755_boot.bin 0x08000000
st-flash write examples/h755_threadx/build/factory.img 0x08020000
st-flash write examples/h755_m4_app/build/h755_m4_app.bin 0x08100000  # bank 2: the satellite
st-flash reset        # boot verifies header+CRC and jumps; the app appears on can0
```

The boot manager owns only the CM7 app slot — **CAN field updates do not refresh the
CM4 image**; it rides bank 2 and is reflashed over SWD when its config changes.

**Every time after (field, over CAN):** the app's `boot` shell command reboots into the
boot manager (no reply — silence is the ack, the reset preempts it), then the flasher
drives the whole UDS session (erase, transfer, on-target CRC, valid mark, reset):

```sh
cansend can0 7F0#626F6F74      # ascii "boot" -> app traffic stops, boot mode
cd ../blobly_net
v -enable-globals -path "@vlib|@vmodules|modules" run cmd/flash \
    can0 ../blobly_emb/examples/h755_threadx/build/field.img 08020000 7B0 7B8 <sw_version>
# ...
# flash: image verified + marked valid
# flash: ECU reset — done          <- the app is running again
```

A transfer cut anywhere leaves an image the boot
refuses (valid mark last) — the board sits in programming mode and a plain re-run of
`cmd/flash` recovers it. All bench-verified, including pull-power mid-transfer
([../bootloader.md](../bootloader.md) bench log).

## 3. blobly_net — CLI and GUI

blobly_net is the tester side (an automotive bus tester, own repo). Everything speaks plain
SocketCAN, so it works against vcan0 sims and the real bench alike.

**GUI** — yes, it exists: a native Dear ImGui app.

```sh
cd ../blobly_net
scripts/setup_env.sh      # once: GLFW + FreeType etc.
BLOBLY_PROJECT=projects/trace-h755-threadx.blobnet scripts/run_vgui.sh
```

A **project** (`projects/*.blobnet`) wires the panels for a target —
`trace-h755-threadx.blobnet` is the H755 bench project: bus monitor,
**Trace panel** (Record / Stop / Dump → the multi-core swimlane, needs the example's
`gen/trace-manifest.csv`), **Shell panel** (`ps`, `stat`, `nm`, `bmc`, `boot`, ... with
history — it handles the ISO-TP flow control a bare `cansend` doesn't), dashboards for
signals, and the Lua **Script panel**.

**CLI tools** (`cmd/`, run like `cmd/flash` above):

| tool | what |
|---|---|
| `cmd/flash` | the UDS flasher (section 2) — **CLI only; no GUI flash panel yet** |
| `cmd/trace_dump` | arm/stop/stream a trace window, decoded with the manifest |
| `cmd/dbc_decode`, `cmd/signal_decode` | bus decoding against a DBC |
| `scripts/runtests.sh` | headless Lua test runner (CI) |

**Shell from the raw CLI** (no GUI): single frame in, ISO-TP out — but nearly every
response is multi-frame, and a multi-frame response needs a flow control on the `fc`
id. Start the receiver first, then send:

```sh
isotprecv -s 0x7F2 -d 0x7F1 can0 &     # answers the FF with the flow control
cansend can0 7F0#7073                  # "ps"
```

A bare `cansend` without the receiver wastes that response: the shell waits for the
flow control, times out after ~1 s (ISO-TP N_Bs), and recovers — retry with the
receiver running. The GUI shell panel does all of this for you.

## Debugging the target

- **Use OpenOCD** for anything forensic: `openocd -f interface/stlink.cfg -f
  target/stm32h7x.cfg`, then `gdb-multiarch build/*.elf -ex 'target extended-remote
  :3333'`. Its reset semantics are trustworthy and detach resumes cleanly.
- **st-util resets the target on connect** — every attach shows you a seconds-old fresh
  boot, which silently invalidates post-mortems (`--no-reset` attaches live, but detach
  can leave the core halted). Fine for quick pokes, not for forensics.
- A board that ACKs frames but sends nothing may be HardFault-parked — the FDCAN ACKs
  autonomously. Check the PC before blaming the wire.
