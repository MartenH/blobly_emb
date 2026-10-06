-- @project diag_bench.blobnet
-- @verifies REQ-DIAG-013 REQ-DIAG-014 REQ-DIAG-016
-- The PERSISTED fault memory on the target (docs/diagnostics.md §3.3, R6b): zone_a (H723, the
-- edge bus) keeps its DTC, counters and snapshot in the NvM journal (boards/h723/bootmap.h, flash
-- sectors 6 + 7). Same fault as faults_zone_a.lua: SteerLimiter fails VehicleSpeed above 250 km/h,
-- which only this script's injected frames carry. The operation cycle is the power cycle, so every
-- MCU reset ends one: what the cycle saw is closed at the next boot (pending clears after a passing
-- cycle, a confirmed DTC ages, aging = 3).
--
-- Needs blobly_net with 0x19 03/04/06 (diag:snapshot / snapshot_ids / extended, check.snapshot /
-- check.extended). Bench only (zone_a flashed with its bootloader — `make flash` in
-- nodes/zone_a — on the CANsub, edge = channel 1):
--   BLOBLY_NET=/path/to/blobly_net; v -enable-globals -path "@vlib|@vmodules|$BLOBLY_NET/modules" \
--     run $BLOBLY_NET/cmd/script/run.v examples/system_full/test/faults_zone_a_persist.lua
-- The power-cut test runs only when BLOB_ZONE_A_POWER_CUT names a command that cuts zone_a's power
-- (or resets it with no warning to the firmware, e.g. `st-flash --serial $BLOB_H723_SERIAL reset`
-- — a reset the firmware does not see coming is what a power loss is to the journal) and returns
-- once it is back; without it that test logs that it was skipped.

local DTC = "U0401-00" -- 0xC40100, SpeedImplausible (nodes/zone_a/ecu.toml)
local IMPLAUSIBLE = "\x2C\x01\x00\x00\x00\x00\x00\x00" -- 300 km/h, u32 LE at bit 0 (edge.dbc)
local BOOT_MS = 3000 -- the bootloader's check, the application's start, the journal's mount

local function diag() return uds.open("edge", { tx = 0x7C0, rx = 0x7C8 }) end

local function implausible(ms)
  local t = 0
  while t < ms do
    bus.send("edge", 0x130, IMPLAUSIBLE)
    sleep_ms(4)
    t = t + 4
  end
end

-- inject the implausible speed in BURST_MS bursts, reading the status after each, until DTC's status
-- bit `bit` is set or MAX_BURSTS have gone: the bursts it took, or nil. Not one fixed window,
-- because the gateway's plausible copy of 0x130 competes: a dispatch that reads it moves the
-- accumulating counter down, so qualifying takes a varying number of dispatches.
local BURST_MS, MAX_BURSTS = 300, 10
local function fail_until(d, bit)
  for n = 1, MAX_BURSTS do
    implausible(BURST_MS)
    for _, e in ipairs(d:supported_dtcs()) do
      if e.name == DTC and e[bit] then return n end
    end
  end
  return nil
end

-- an ECUReset: answered, then the MCU restarts — the flush first (the journal written whole)
local function reset(d)
  d:reset(0x01)
  sleep_ms(BOOT_MS)
end

local function clean(d)
  d:clear_dtcs()
  sleep_ms(400)
  check.dtc(d, DTC, { confirmedDTC = false, pendingDTC = false, testFailedSinceLastClear = false })
end

-- confirmed in this power cycle, then the gateway's plausible speeds pass it again
local function confirm(d)
  fail_until(d, "confirmedDTC")
  check.dtc(d, DTC, { confirmedDTC = true, pendingDTC = true, testFailedThisOperationCycle = true })
  sleep_ms(600)
end

test("zone_a: the first failure takes a snapshot (0x19 03 / 04) and counts (0x19 06)", function()
  local d = diag()
  clean(d)
  check.equal(#d:snapshot_ids(), 0, "a snapshot listed after a clear")
  confirm(d)
  local ids = d:snapshot_ids()
  check.equal(#ids, 1)
  check.equal(ids[1].name, DTC)
  check.equal(ids[1].record, 0x01)
  local s = d:snapshot(DTC)
  check.equal(#s.records, 1)
  check.equal(s.records[1].number, 0x01)
  check.equal(#s.records[1].dids, 1)
  check.equal(s.records[1].dids[1].id, 0xF1A0) -- the steering angle on the wire at the failure
  check.equal(#s.records[1].dids[1].data, 4)
  log(string.format("%s snapshot: SteeringAngle %s", DTC, tohex(s.records[1].dids[1].data)))
  check.extended(d, DTC, { occurrence = 1, aging = 0, failed_cycles = 1 })
  -- a later occurrence counts, and keeps the FIRST failure's snapshot
  check.dtc(d, DTC, { testFailed = false })
  check.truthy(fail_until(d, "testFailed"), "the second failure did not qualify")
  sleep_ms(600)
  local e = d:extended(DTC)
  check.truthy(e.occurrence >= 2, "a second occurrence was not counted")
  check.snapshot(d, DTC, { [0xF1A0] = s.records[1].dids[1].data })
end)

test("zone_a: an ECUReset keeps the DTC, its counters and its snapshot; testFailed restarts", function()
  local d = diag()
  clean(d)
  confirm(d)
  local before = d:snapshot(DTC).records[1].dids[1].data
  local occ = d:extended(DTC).occurrence
  reset(d)
  d = diag()
  -- the cycle the reset ended failed: still pending; this one has not tested yet when it boots
  local r = check.dtc(d, DTC, { confirmedDTC = true, pendingDTC = true, testFailedSinceLastClear = true,
    testFailedThisOperationCycle = false })
  log(string.format("%s status 0x%02X after the reset", DTC, r.status))
  check.snapshot(d, DTC, { [0xF1A0] = before })
  check.extended(d, DTC, { occurrence = occ, aging = 0, failed_cycles = 1 })
end)

test("zone_a: a passing power cycle clears pending; a confirmed DTC ages over them", function()
  local d = diag()
  clean(d)
  confirm(d)
  reset(d) -- cycle 1 failed: pending stays
  d = diag()
  sleep_ms(600) -- cycle 2: plausible speeds pass the test
  reset(d)
  d = diag()
  check.dtc(d, DTC, { confirmedDTC = true, pendingDTC = false, testFailed = false })
  check.extended(d, DTC, { aging = 1, failed_cycles = 1 })
  check.equal(#d:snapshot_ids(), 1, "a confirmed DTC lost its snapshot")
  -- two more passing cycles: aged out (aging = 3) — confirmation and the snapshot go, the history stays
  for _ = 1, 2 do
    sleep_ms(600)
    reset(d)
    d = diag()
  end
  check.dtc(d, DTC, { confirmedDTC = false, pendingDTC = false, testFailedSinceLastClear = true })
  check.equal(#d:snapshot_ids(), 0, "an aged-out DTC kept its snapshot")
end)

test("zone_a: a clear is durable before it is answered", function()
  local d = diag()
  clean(d)
  confirm(d)
  d:clear_dtcs()
  reset(d)
  d = diag()
  check.dtc(d, DTC, { confirmedDTC = false, pendingDTC = false, testFailedSinceLastClear = false })
  check.equal(#d:snapshot_ids(), 0)
  check.extended(d, DTC, { occurrence = 0, aging = 0, failed_cycles = 0 })
end)

test("zone_a: a power cut with no warning keeps what the journal already holds", function()
  local cmd = os.getenv("BLOB_ZONE_A_POWER_CUT")
  if cmd == nil or cmd == "" then
    log("skipped: set BLOB_ZONE_A_POWER_CUT to a command that cuts zone_a's power and restores it")
    return
  end
  local d = diag()
  clean(d)
  fail_until(d, "confirmedDTC") -- the first failure: written in the pass that saw it
  local snap = d:snapshot(DTC).records[1].dids[1].data
  sleep_ms(200)
  check.truthy(os.execute(cmd), "the power-cut command failed: " .. cmd)
  sleep_ms(BOOT_MS)
  d = diag()
  check.dtc(d, DTC, { confirmedDTC = true, pendingDTC = true, testFailedSinceLastClear = true, testFailed = false })
  check.snapshot(d, DTC, { [0xF1A0] = snap })
  -- the occurrence that set pending is durable; later ones in that cycle wait for a flush
  local e = d:extended(DTC)
  check.truthy(e.occurrence >= 1, "the first occurrence was lost to the power cut")
  check.equal(e.failed_cycles, 1)
  d:clear_dtcs()
end)
