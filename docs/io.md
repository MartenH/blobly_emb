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
period_ms = 10            # publish cadence (conversion free-runs; see below)

[[io.gpio]]
name      = "UserButton"  # input: publishes; direction from the signal's flow
pin       = "PC13"
period_ms = 10

[[io.gpio]]
name      = "LedGreen"    # output: consumed (an FB writes it)
pin       = "PB0"
period_ms = 10            # apply cadence — every point declares one
init      = false         # REQUIRED on outputs: the pre-publication pin state

[[io.pwm]]
name      = "FanDuty"     # output: duty from the signal value (0..1000 permille)
pin       = "PE9"
period_ms = 10
freq_hz   = 20000
init      = 0             # duty before the first publication
```

`period_ms` is mandatory on every point, outputs included — it is the io
thread's contract for that point (publish inputs / apply outputs at this
cadence). The io thread runs at the fastest configured period and serves each
point on its own multiple; without this an output-only ECU would have no
defined cadence at all.

The io thread's **home core** is config: an optional top-level `[io]` table
with `core = N`, defaulting to the IO core (core 0 — where the bus bridges
already live, the comm-thread precedent). That placement is what the
same-core/cross-core transport derivation below is computed against, and on
the MPU target it decides which peripheral region the platform partition maps.

Each `[[io.*]]` entry names a `[[signal]]`; the signal's `from`/`to` gains a third
endpoint class, **io** (next to partition and bus): `from = "io"` = an input the
platform publishes, `to = "io"` = an output the platform drives. Direction is
therefore declared once, on the signal, and the generator cross-checks it against
the io kind (an `[[io.adc]]` bound to a `to = "io"` signal is a config error).
`io` becomes a **reserved endpoint name**: ecucheck rejects a partition, thread,
or bus named `io` (endpoints resolve by name, so a user `io` partition would be
ambiguous against this class — same rule family as the TOML nested-comment guard).
ecucheck also validates the **binding, shape, and transport** of an io-bound
signal:

- **one-to-one binding**: every `from/to = "io"` signal has exactly ONE matching
  `[[io.*]]` entry, and every io point names exactly one such signal — an
  unmatched io signal would otherwise silently resolve as a phantom endpoint
  with no physical producer, and duplicates would be an ambiguous pin binding;
- **shape per kind**: exactly one field, an aligned scalar of at most 32 bits
  (a single atomic load in the latest-value handoff), AND the type fits the
  kind — gpio: `bool`; adc: `u16`/`u32`; pwm: `u16`/`u32` (a `u8` cannot carry
  0..1000 permille, an `f32` has no defined digital-level meaning);
- **transport is topology-derived, not chosen**: same-core consumer → `triple`;
  cross-core consumer → `xioc` (the plain-store slot protocol) — exactly the
  derivation ordinary signals already use, and for the recorded reason: triple
  across H755 cores tore 162 reads before xioc replaced it, while `seqlock`
  retries under a saturating writer (not wait-free) and `double` tears when the
  reader is preempted across two publishes (docs/multicore-perf.md). An explicit
  `transport =` on an io-bound signal is a config error — the generator derives
  the only correct one per edge;
- **periods harmonic**: every `period_ms` is at least 1 (the Loom tick — zero
  or negative would make "fastest" divide-by-zero or saturate the io core) and
  an integer multiple of the fastest configured io period — the io thread runs at the fastest and serves each
  point on its own multiple, so a non-divisible cadence (7 ms vs 10 ms) would
  silently publish off-spec; ecucheck rejects it instead.

## Derived glue (the duo_gen.h pattern, third use)

The generator assigns each io point a channel index and emits `gen/io_gen.h` — the
contract header the example's/boards' C glue compiles against. The V side never sees
pins or peripherals:

- **The platform io thread owns every pin touch.** Peripheral registers belong to
  the platform partition — on the MPU target an application partition has no
  peripheral region (docs/memory-protection.md), so app threads can neither sample
  inputs nor apply outputs themselves. The generator therefore emits a first-class
  **io thread** (the comm-thread precedent, [[platform-scheduling-comm-thread]]):
  each period it samples the due input points and publishes them, and acquires
  output points and applies them. App threads only ever see signal cells.
- **Fan-out stays SPSC.** The io thread is the single producer of every input
  signal; a point consumed by several threads gets **one generated channel per
  consumer edge** (the io thread publishes the same sample into each), because
  `double`/`triple` are single-reader transports — fan-out by channel
  multiplication, never by multi-reader channels or re-sampling the pin. One
  hardware sample per period, every consumer sees the same value, wait-free on
  both sides.
- **Inputs**: sampled wait-free. The ADC is configured ONCE at init — continuous
  scan mode over the configured channels, circular DMA into a latest-value array —
  and free-runs from then on; no timers, no conversion interrupts, no per-sample
  management (the IOC philosophy applied to the pin: the io thread READS, never
  waits). GPIO reads are direct. Two cadences, deliberately decoupled: conversions
  free-run (hardware's business), while `period_ms` is the PUBLISH cadence — the
  io thread's copy from latest-value array into the signal channels. Values are
  ≤32-bit aligned scalars (ADC counts, levels, permille), so the DMA-array read
  is a single atomic load. Equidistant sampling would only matter for
  signal-processing use — which is a non-goal below. (NM footnote: stopping the
  free-running ADC/DMA at sleep-entry is platform lifecycle, the same hook family
  as the transceiver — P4.)
- **Outputs**: the io thread acquires each output signal's channel and applies it —
  GPIO write / PWM compare-register update, both near-free — **gated on
  freshness**: until the producing FB has published at least once, the io thread
  keeps applying the configured `init`, never the channel's zero-initialized
  unread value (the host IOC API already reports freshness; the target slot
  protocol grows the same bit when the target phase lands). PWM signal value =
  duty in permille (0..1000), **clamped to 1000** above range — a u16 can carry
  1001..65535 and the clamp makes the out-of-range policy deterministic across
  timer backends instead of backend-dependent wrap/saturate. The carrier
  `freq_hz` is config, not data.
  **Before the first publication** (startup, a disabled FB, a delayed first
  activation) the pin holds its configured `init` value — every output point
  declares one (`init = false` level, `init = 0` duty), applied by the io
  thread at its own init, BEFORE the app starts. No window where the pin state
  is whatever the peripheral reset left behind, and no accidental drive from an
  unpublished zero-value channel.
- **Startup ordering — inputs too**: the io thread publishes ONE initial sample
  of every input (waiting out the ADC's first conversion) before application
  dispatch begins, so the first activation never reads an empty channel's zero
  as if it were a hardware sample. Same ordering rule the deterministic
  start-up chain already imposes (SYS-REQ-LIFE-001): platform first, app after.
- The C implementations (`io_adc_read(ch)`, `io_gpio_read/write(ch)`,
  `io_pwm_set(ch, permille)`) live behind a **driver io port** (`driver/io`,
  the same seam as `driver/can`): a platform-independent port header with a
  host backend (the sim's file mirror) and target backends that own the
  registers, fed by the board's pin table. Generated code calls the port and
  nothing else — C interop stays behind the OSAL/driver boundary (AGENTS.md);
  boards/example glue never surface functions into generated code. Two explicit
  port-contract clauses for the latest-value handoff: (1) the DMA region must
  be **non-cacheable or cache-maintained by the backend** — an aligned load
  alone does not guarantee freshness through a data cache (today's H7 boards
  run D-cache off by policy, which satisfies it trivially); (2) the backend
  must write each sample **single-copy-atomically at the signal's width** and
  the CPU accessor must be **volatile** — a DMA that beats a u32 out in bytes,
  or a compiler that caches the load, can serve a torn or stale value through
  a perfectly aligned address.
- **Management plane**: the io thread is a platform thread like the comm
  thread, and joins the same choreography — it appears in the manifest and
  trace by name, checkpoints the watchdog (a stuck io thread must not leave
  stale actuator values behind a happily-fed watchdog), and takes the
  quiesce/resume mode events: at sleep-entry it stops the free-running
  ADC/DMA, drives outputs to their `init` values, and parks; wake restarts
  the sampling before the app resumes (the NM/NvM in-sleep pattern;
  REQ-IO-009 makes this choreography traceable evidence, not a hope).

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
  transceiver's wake output is a wake source. Seam: a **driver-port call**
  (`blob_can_xcvr_mode(bus, mode)` in the CAN driver port, beside open/send/recv
  — NOT a bare boards hook: generated/NM code must stay behind the driver
  boundary like all C interop). The default backend is a no-op (today's bench
  transceivers strap STB to GND, i.e. permanently normal — the port makes that
  a board property, not a design assumption); a target backend drives the
  board's pin table. **The comm thread makes the call, not NM directly**: the
  comm thread exclusively owns the bus driver (docs/architecture.md), and on
  the dedicated-mode-thread topology NM runs elsewhere — so NM emits its state
  transition as a mode event and the comm-thread owner applies the transceiver
  mode through the port, on transitions and ONCE at init to establish the
  configured initial state (NM starts in `bus_sleep` without a transition, and
  a transceiver that powers up in normal mode must not stay awake while NM
  reports sleep). Nothing else touches it.
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
this is enough to develop the whole layer dry. **The io thread makes this safe by
construction**: on host, the same platform io thread does the file work in both
directions — it polls `io/<name>` into its latest-value array (tolerating a
mid-`echo` torn read; the next poll heals it) and writes output files after
applying (the hardware's compare-register write becomes an `io/<name>` write).
App threads never touch a file: values cross on the same generated SPSC channels
as on target, which is also what makes the handoff race-free — no plain shared
array between threads, no C-level data race. A blocking or truncated filesystem
op can delay the io thread's next period, never an app loop; the wait-free /
latest-complete-sample contract (REQ-IO-003) holds identically in both worlds.
One subtlety: a bare `echo 100 > io/PotVolt` is not atomic — a mid-write read
could see `1`, syntactically valid but never a supplied value. The update
protocol is therefore write-then-rename (`io/.PotVolt.tmp` → `io/PotVolt`,
atomic on POSIX; a two-line `ioset` helper ships with the sim) — and the io
thread's own OUTPUT writes use the same temp-and-rename, so a GUI or test
reading an actuator file never observes a truncated value either. The reader
keeps the LAST-GOOD value whenever a read is empty or unparsable — a partial
supplied value can still slip through a non-conforming writer, which is the
sim's documented cost of file transparency, not a violation the target can hit.

## Phasing (each rung gated; bench when silicon is back)

1. **P1 — GPIO** in/out on the H755 (user LED + button are on-board: button →
   CAN frame, shell → LED — observable with nothing but the bench). Model +
   generator + `io_gen.h` + boards glue land here.
2. **P2 — ADC** inputs (continuous-scan + circular-DMA latest-value, no timers —
   the free-running model above; the wait-free contract).
3. **P3 — PWM** outputs.
4. **P4 — NM transceiver port** (`blob_can_xcvr_mode`) + wake source — needs a board
   with a controllable transceiver on the bench.
5. **P5 — irq-triggered handlers** (the reserved trigger) when a real use case
   demands sub-tick latency.
