# Signal ↔ IO — design

> Status: DESIGN (2026-07-14). Requirements: `requirements/io.toml` (draft, deriving
> from SYS-REQ-IO-001). Nothing is built; this page is the shape to argue with.
> (AUTOSAR-comparison note: this is the territory IoHwAb + MCAL drivers occupy —
> blobly's version is signal endpoints + the boards layer, no new abstraction.)

## The one idea

An IO point is a **signal endpoint**, exactly as a bus or a partition is one. The
application never sees hardware — it reads `inp.pot_volt` and writes `outp.fan_duty`
like any other port field; the generator emits the sampling/driving glue; the boards
layer owns pins, timers, ADCs. Adding an IO point is config, not code — the same
absorption move the model has made twice already (bus endpoints → COM codec,
cross-core endpoints → xioc slots).

```toml
[[io.adc]]
name      = "PotVolt"     # publishes the [[signal]] of the same name
pin       = "PA3"
period_ms = 10            # sample cadence

[[io.gpio]]
name      = "UserButton"  # input: publishes; direction from the signal's flow
pin       = "PC13"
period_ms = 10

[[io.gpio]]
name      = "LedGreen"    # output: consumed (an FB writes it)
pin       = "PB0"

[[io.pwm]]
name      = "FanDuty"     # output: duty from the signal value (0..1000 permille)
pin       = "PE9"
freq_hz   = 20000
```

Each `[[io.*]]` entry names a `[[signal]]`; the signal's `from`/`to` gains a third
endpoint class, **io** (next to partition and bus): `from = "io"` = an input the
platform publishes, `to = "io"` = an output the platform drives. Direction is
therefore declared once, on the signal, and the generator cross-checks it against
the io kind (an `[[io.adc]]` bound to a `to = "io"` signal is a config error).
`io` becomes a **reserved endpoint name**: ecucheck rejects a partition, thread,
or bus named `io` (endpoints resolve by name, so a user `io` partition would be
ambiguous against this class — same rule family as the TOML nested-comment guard).

## Derived glue (the duo_gen.h pattern, third use)

The generator assigns each io point a channel index and emits `gen/io_gen.h` — the
contract header the example's/boards' C glue compiles against. The V side never sees
pins or peripherals:

- **Inputs**: sampled wait-free. The ADC is configured ONCE at init — continuous
  scan mode over the configured channels, circular DMA into a latest-value array —
  and free-runs from then on; no timers, no conversion interrupts, no per-sample
  management (the IOC philosophy applied to the pin: the loop READS, never waits).
  GPIO reads are direct. Two cadences, deliberately decoupled: conversions free-run
  (hardware's business), while `period_ms` is the PUBLISH cadence — when the
  generated loop copies the latest value into the signal's cell, before dispatch,
  so FBs see a coherent snapshot as always. **Single-writer, like every signal**:
  an io input is homed to exactly ONE thread (where its consuming FB runs; with
  consumers on several threads, the generator homes it to one — config picks, the
  same way a signal's producer is unique today) and only that thread's loop
  samples-and-publishes. Every other consumer acquires the published value over
  the ordinary cross-thread transport (IOC) — never by re-sampling the pin. One
  hardware sample per period, one producer per cell; the SPSC invariant holds and
  all consumers see the same value. Equidistant sampling would only matter
  for signal-processing use — which is a non-goal below. (NM footnote: stopping the
  free-running ADC/DMA at sleep-entry is platform lifecycle, the same hook family
  as the transceiver — P4.)
- **Outputs**: applied after dispatch — GPIO write / PWM compare-register update,
  both near-free. PWM signal value = duty in permille (0..1000); the carrier
  `freq_hz` is config, not data.
- The C implementations (`io_adc_read(ch)`, `io_gpio_read/write(ch)`,
  `io_pwm_set(ch, permille)`) live in the boards layer / example glue, exactly as
  `duo_pub`/`comm_glue.c` do today.

Pins are named in ecu.toml because an example is already board-specific (it selects
`BOARD` in its Makefile); the glue C validates the pin table at compile time. If a
second board ever runs the same ecu.toml, pin mapping moves into the boards layer —
a relocation, not a redesign.

## The two classes of pins (do not mix them)

**Application IO points** (above): pins whose *values* are the app's business.

**Platform pins**: pins whose *lifecycle* belongs to a platform unit — the CAN
transceiver's STB/EN, an Ethernet PHY's reset/power-down, a click board's CS. These
are NOT signals, never appear in `[[io.*]]`, and never reach the application. The
boards layer owns the pin; the owning platform module owns the WHEN:

- **CAN transceiver ← NM.** The transceiver mode pin follows the network state
  machine: normal while awake, standby on bus_sleep, and (where wired) the
  transceiver's wake output is a wake source. Seam: `board_can_mode(bus, mode)` —
  a boards-layer hook, default no-op (today's bench transceivers strap STB to GND,
  i.e. permanently normal — the hook makes that a board property, not a design
  assumption). NM calls it on its sleep/wake transitions; nothing else does.
- **Ethernet PHY ← the net stack.** NetX Duo's driver calls PHY hooks
  (reset, link poll, power-down) that the boards layer provides. Same shape.
- Litmus test for which class a pin is: *would an FB ever read or write it?* If the
  answer needs the word "mode" or "power", it's a platform pin.

## What this deliberately is NOT

- **Not a hard-real-time IO path.** Loom ticks are 1 ms; a multi-kHz control loop
  does not fit. The seam is already reserved — `[[fb.handler]] irq` (rejected today)
  becomes an interrupt-triggered handler when a use case earns it. Until then, io
  points are for signals that live happily at >= 1 ms cadence.
- **Not filtering/scaling/calibration.** An io signal carries the raw sampled value
  (ADC counts, permille duty); conditioning is FB work — visible, testable,
  traceable like all app logic.
- **Not event capture.** A button EDGE between samples is missable by design at
  P1-P3 (sampled inputs); edge/capture IO arrives with the irq-handler phase.

## Sim story (sim-first, as always)

Host examples back io points with **files** (the boot_sim flash.bin move): an input
point reads its value from `io/<name>`, an output writes there — a shell/GUI pokes
inputs and watches outputs with zero target hardware. The FlashOps precedent says
this is enough to develop the whole layer dry. **File access never sits on the
sampled path**: the sim's io glue mirrors the ADC/DMA shape — a background reader
polls `io/<name>` at its own pace into an in-memory latest-value array (tolerating
a mid-`echo` torn read; the next poll heals it), and the dispatch-path
`io_*_read(ch)` is a plain memory read, exactly as on target. The wait-free /
latest-complete-sample contract (REQ-IO-003) holds in both worlds; a blocking or
truncated filesystem op can delay the mirror, never the loop.

## Phasing (each rung gated; bench when silicon is back)

1. **P1 — GPIO** in/out on the H755 (user LED + button are on-board: button →
   CAN frame, shell → LED — observable with nothing but the bench). Model +
   generator + `io_gen.h` + boards glue land here.
2. **P2 — ADC** inputs (timer + DMA latest-value; the wait-free contract).
3. **P3 — PWM** outputs.
4. **P4 — NM transceiver hook** (`board_can_mode`) + wake source — needs a board
   with a controllable transceiver on the bench.
5. **P5 — irq-triggered handlers** (the reserved trigger) when a real use case
   demands sub-tick latency.
