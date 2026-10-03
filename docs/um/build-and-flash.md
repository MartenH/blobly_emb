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
+0x400) — the board's `bootmap.h` says so, and nothing else does. A node that declares
**`[boot]`** in its `ecu.toml` (the `system_full` CAN nodes: domain, sysnode, zone_a) gets
everything from its own config, through `gen/loom_build.mk` → `boot/boot.mk`:

- its application **linked at the app slot** (`make` — no flag: the link follows `[boot]`);
- its **boot manager**, one program for every board and node (`boot/target/main.v`), built
  on the node's `[isotp]` ids, bus and frame format and its `[boot]` keys (`make boot`,
  part of `make`) — so a tester addresses the app and then its boot identically;
- both **image containers** (`make image SW_VERSION=<n>`): `build/<node>.img`, signed and
  unmarked (the boot verifies it and writes the mark LAST — the torn-transfer guarantee),
  and `build/<node>-factory.img`, pre-marked, for SWD only.

**First time (factory, over SWD):** `make flash` on such a node is `boot-flash` — the boot at
0x08000000, the factory image at APP_BASE, a reset:

```sh
make -C examples/system_full/nodes/domain flash SERIAL=<sn> SW_VERSION=1
make -C examples/system_full/nodes/domain_m4 flash SERIAL=<sn>   # H755 bank 2: the CM4 satellite
```

The boot manager owns only the CM7 app slot — **CAN field updates do not refresh the
CM4 image**; it rides bank 2 and is reflashed over SWD when its config changes.

**Every time after (field, over CAN):** the application's diagnostic server hands over
itself — `0x10 03`, then `0x10 02` (behind 0x27 where its `"0x10 02"` row asks): it answers
`50 02`, writes the boot request cell and resets, and the boot opens the programming session
on the same ids. The flasher then drives the UDS session (0x29, erase, transfer, on-target
check, valid mark, reset):

```sh
make -C examples/system_full/nodes/zone_a image SW_VERSION=8
cd ../blobly_net
v -enable-globals -path "@vlib|@vmodules|modules" run cmd/flash \
    cansub:e5a16adf/1@500000/2000000 ../blobly_emb/examples/system_full/nodes/zone_a/build/zone_a.img 08020000 7C0 7C8 8
```

`examples/system_full/test/boot_bench.sh` is that loop for each node, with the handoff and the
version check in Lua (`boot_handoff.lua`). A transfer cut anywhere leaves an image the boot
refuses (valid mark last) — the board sits in programming mode and a plain re-run of
`cmd/flash` recovers it ([../bootloader.md](../bootloader.md) bench log).

The standalone examples `h755_threadx` / `h735_threadx` keep `make APP_LINK=boot` (an image for
the app slot) and their `boot` shell command (the request cell, then a reset); the boot that
serves them is a `[boot]` node's on the same board.

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
