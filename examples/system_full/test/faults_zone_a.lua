-- @project diag_bench.blobnet
-- Faults on the TARGET (docs/diagnostics.md R6): zone_a (H723, the edge bus) keeps a fault memory on
-- its ThreadX comm thread. SteerLimiter tests the VehicleSpeed it receives for plausibility each 50 ms
-- dispatch (above 250 km/h fails it); the Loom debounces the result on front_thread (an accumulating
-- counter, +3 to fail, -3 to pass: 150 ms from a clean start, 300 ms back) and the comm thread turns it into DTC U0401-00's ISO 14229-1 status, read with 0x19,
-- cleared with 0x14, frozen with 0x85. The operation cycle is the power cycle ([fault_memory] cycle =
-- "power"): begun at boot, so nothing here ends it — pending stays set within it.
--
-- The domain's speed lies in 60..119 km/h, so only this script can fail the test: it sends
-- VehSpeedFrame_E (0x130) on edge every few ms carrying 300 km/h, beside the gateway's own copy every
-- 100 ms. The FB reads the latest value at each dispatch, so nearly every dispatch fails and the
-- accumulating counter qualifies; once the script stops, the gateway's plausible values pass it again.
-- (Two senders of one id can collide in arbitration with different data — an occasional error frame,
-- retransmitted; harmless on a bench.) Bench only (the flashed board on the CANsub, edge = channel 1):
--   BLOBLY_NET=/path/to/blobly_net; v -enable-globals -path "@vlib|@vmodules|$BLOBLY_NET/modules" \
--     run $BLOBLY_NET/cmd/script/run.v examples/system_full/test/faults_zone_a.lua

local DTC = "U0401-00" -- 0xC40100, SpeedImplausible (nodes/zone_a/ecu.toml)
local IMPLAUSIBLE = "\x2C\x01\x00\x00\x00\x00\x00\x00" -- 300 km/h, u32 LE at bit 0 (edge.dbc)

local function diag() return uds.open("edge", { tx = 0x7C0, rx = 0x7C8 }) end

-- inject the implausible speed for `ms`
local function implausible(ms)
  local t = 0
  while t < ms do
    bus.send("edge", 0x130, IMPLAUSIBLE)
    sleep_ms(4)
    t = t + 4
  end
end

-- the entry for DTC `name` in a 0x19 list, or nil. zone_a declares other faults too — the
-- signal-status faults on SafetyCmd (R5), which this bench project does not simulate the sender
-- of, so its timeout DTC confirms here — so a check selects its own DTC and never counts the list.
local function find(list, name)
  for _, e in ipairs(list) do
    if e.name == name then return e end
  end
  return nil
end

-- a clean slate: cleared, then long enough for the producer to apply the clear and pass its test
local function clean(d)
  d:clear_dtcs()
  sleep_ms(400)
  check.dtc(d, DTC, { testFailed = false, confirmedDTC = false, pendingDTC = false,
    testFailedSinceLastClear = false, testNotCompletedSinceLastClear = false })
end

test("zone_a: the fault memory serves its DTC, passing with plausible speeds", function()
  local d = diag()
  clean(d)
  check.truthy(find(d:supported_dtcs(), DTC) ~= nil, DTC .. " is not among zone_a's DTCs")
  check.truthy(find(d:dtcs(0x09), DTC) == nil, DTC .. " failed or confirmed while the speed was plausible")
end)

test("zone_a: an implausible speed confirms the DTC; plausible speeds clear testFailed only", function()
  local d = diag()
  clean(d)
  implausible(600)
  local r = check.dtc(d, DTC, { confirmedDTC = true, pendingDTC = true,
    testFailedThisOperationCycle = true, testFailedSinceLastClear = true })
  log(string.format("%s status 0x%02X after the injection", DTC, r.status))
  check.truthy(find(d:dtcs(0x08), DTC) ~= nil, DTC .. " is not listed as confirmed")
  -- the gateway's own speed passes the test again: the history stays (one power cycle)
  sleep_ms(600)
  check.dtc(d, DTC, { testFailed = false, confirmedDTC = true, pendingDTC = true,
    testFailedThisOperationCycle = true })
end)

test("zone_a: 0x14 clears the DTC (by number and as a group)", function()
  local d = diag()
  clean(d)
  implausible(600)
  check.dtc(d, DTC, { confirmedDTC = true })
  sleep_ms(600)
  d:clear_dtcs(0xC40100) -- by number
  sleep_ms(400)
  check.dtc(d, DTC, { testFailed = false, confirmedDTC = false, testFailedSinceLastClear = false })
  check.nrc(0x31, function() d:clear_dtcs(0xC40200) end) -- no such DTC on this node
end)

-- cleared WHILE failing: the clear reaches the producer as a new generation, so its debounce starts
-- over — the reports it made before cannot bring the DTC back (they carry the old generation), and
-- only failing again after the clear does
test("zone_a: a DTC cleared while failing returns only by failing again", function()
  local d = diag()
  clean(d)
  implausible(600)
  d:clear_dtcs()
  check.dtc(d, DTC, { confirmedDTC = false, testFailedSinceLastClear = false })
  sleep_ms(600) -- plausible speeds: the restarted debounce passes
  check.dtc(d, DTC, { testFailed = false, confirmedDTC = false, testFailedSinceLastClear = false })
  implausible(600) -- failing again after the clear
  check.dtc(d, DTC, { confirmedDTC = true, testFailedSinceLastClear = true })
  sleep_ms(600)
  d:clear_dtcs()
  check.dtc(d, DTC, { confirmedDTC = false })
end)

test("zone_a: with DTC setting off (0x85, extended session) nothing is recorded", function()
  local d = diag()
  clean(d)
  check.nrc(0x7F, function() d:dtc_setting(false) end) -- not in the default session
  d:session(0x03)
  d:dtc_setting(false)
  implausible(600)
  check.dtc(d, DTC, { testFailed = false, confirmedDTC = false, testFailedSinceLastClear = false })
  d:dtc_setting(true)
  sleep_ms(600) -- passing again: the suppressed failure is not replayed
  check.dtc(d, DTC, { confirmedDTC = false, testFailedSinceLastClear = false })
  d:session(0x01)
end)
