# Telemetry: self-reported processor load

The stack measures its **own** per-core processor load and ships it as an ordinary
CAN message, so a running ECU's load can be watched live in any CAN tool (candump,
or the blobly_net GUI decoding it via DBC) — no `/proc`, no external profiler.

## How it works

1. **Measure** (`loom/`). Each `Scheduler` brackets the time it spends in `run()`
   and rolls it into a per-window duty cycle — `load_permille()`, 0..1000. This is
   *handler work / wall clock*: the useful-work fraction, more precise than total
   thread CPU (it excludes the poll/sleep syscall overhead `/proc` counts, so it
   reads a little lower than a `top`-style figure). `REQ-TELEM-001`.
2. **Publish** (generated). Every partition and bus-bridge loop writes its
   `load_permille()` to a shared-scratch slot (one `u64` per scheduler, single
   writer — an aligned store, no IOC channel needed). loom2v knows each
   scheduler's core.
3. **Report** (generated). A telemetry tx on the bus core sums the per-scheduler
   loads **by core** (compile-time grouping) and sends a `CpuLoad` frame —
   one byte per core = load percent (`comm/telem.encode_cpuload`). `REQ-TELEM-002`.

```
loom Scheduler.load_permille()  ->  scratch[slot]  --sum by core-->  CpuLoad CAN frame
```

## Enable it (config)

```toml
[telemetry]
enabled   = true
bus       = "can0"   # which bus carries the frame
id        = 0x7E0    # CpuLoad CAN id
period_ms = 500
```

The `scale` example turns this on (via `scale_gen`); a `CpuLoad` frame on `vcan0`
carries the 4-core load.

## Watch it

```sh
sudo make vcan
cd examples/scale && make all
scripts/scale-bench.sh &              # drives load + cangen traffic
candump vcan0,7E0:7FF                  # CpuLoad: byte i = core i load %
#  vcan0  7E0  [8]  03 01 01 01 00 00 00 00   <- core0 3%, cores 1-3 ~1%
```

## DBC (for the GUI)

Load this so blobly_net (or any DBC tool) decodes `CpuLoad` into per-core signals
(id `2016` = `0x7E0`):

```
BO_ 2016 CpuLoad: 8 SUT
 SG_ Load_Core0 : 0|8@1+ (1,0) [0|100] "%" Tester
 SG_ Load_Core1 : 8|8@1+ (1,0) [0|100] "%" Tester
 SG_ Load_Core2 : 16|8@1+ (1,0) [0|100] "%" Tester
 SG_ Load_Core3 : 24|8@1+ (1,0) [0|100] "%" Tester
 SG_ Load_Core4 : 32|8@1+ (1,0) [0|100] "%" Tester
 SG_ Load_Core5 : 40|8@1+ (1,0) [0|100] "%" Tester
 SG_ Load_Core6 : 48|8@1+ (1,0) [0|100] "%" Tester
 SG_ Load_Core7 : 56|8@1+ (1,0) [0|100] "%" Tester
```

## Scope

Up to 8 cores fit one classic frame (one byte each). The shared scratch holds 16
scheduler slots; configs with more schedulers than that report the first 16. The
mechanism is host/sim today (SocketCAN); on target the same generated tx runs on
the bus core's bridge.
