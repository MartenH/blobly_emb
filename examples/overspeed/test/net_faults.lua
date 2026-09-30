-- @project netsim.blobnet
-- @verifies REQ-DIAG-011
-- (REQ-E2E-001/002 are verified by comm/e2e's unit tests; a bench-run suite tagged here would
--  read as pending and demote them — this is their on-bus evidence across two implementations.)
-- The brake faults, driven by blobly_net: ChassisECU is SIMULATED by blobly_net and its
-- BrakeStatus stamped with AUTOSAR E2E Profile 1 (netsim.blobnet), which the overspeed app
-- checks with its own Profile 1 — two implementations, one profile. Each fault is blobly_net's
-- fault injection on that sender, and each DTC is read back with ReadDTCInformation decoded
-- (check.dtc): the whole path from a misbehaving sender to the fault memory, with nothing
-- hand-stamped in Lua. (faults.lua covers the same DTCs with hand-built frames.)
--   bad_crc          -> U0418-00 BrakeMsgIntegrity (the frame fails its CRC) — and past 300 ms,
--                       U0121-00 too: a corrupt frame is not a valid one
--   drop, briefly    -> U0418-01 BrakeMsgLost      (a gap in the Profile 1 counter)
--   drop, > 300 ms   -> U0121-00 BrakeMsgTimeout   (E2E's own timeout: no valid frame)
--   freeze_counter   -> U0121-00 as well: a repeat is not a valid frame, so it cannot keep the
--                       sender alive — and it is not an integrity fault (its CRC is right)
-- BrakeStatus is sent every 50 ms. Ignition (0x302) is the operation cycle and has no DBC
-- cadence, so hold() keeps it on while it waits.

local function diag() return uds.open("CAN1", { tx = 0x101, rx = 0x102 }) end
local function hold(ms)
  local t = 0
  while t < ms do
    bus.send("CAN1", 0x302, "\x01")
    sleep_ms(50)
    t = t + 50
  end
end
local function fault(kind, ms) sim.fault("CAN1", "ChassisECU", "BrakeStatus", kind, ms) end
local BRAKE = { "U0121-00", "U0418-00", "U0418-01" }
local function clean(d)
  hold(200)
  d:raw("\x14\xFF\xFF\xFF")
  hold(200)
  for _, n in ipairs(BRAKE) do check.dtc(d, n, { testFailed = false, confirmedDTC = false }) end
end

test("net sim: a Profile 1 brake sender keeps every brake DTC clear", function()
  clean(diag())
  hold(600)
  for _, n in ipairs(BRAKE) do check.dtc(diag(), n, { testFailed = false, confirmedDTC = false }) end
end)

test("net sim: a corrupt CRC is an integrity fault, confirmed and then passing again", function()
  local d = diag()
  clean(d)
  -- two corrupt frames: the gap between VALID frames stays ~100 ms inside E2E's 300 ms timeout
  -- (see the next test), and the status is read once good frames are back rather than raced
  fault("bad_crc", 100)
  hold(400)
  check.dtc(d, "U0418-00", { testFailed = false, confirmedDTC = true, testFailedThisOperationCycle = true })
  check.dtc(d, "U0121-00", { confirmedDTC = false })
end)

-- REQ-E2E-002: a corrupt frame is not a valid one, so corruption that outlasts the timeout is
-- ALSO lost communication — the sender is as absent as a silent one
test("net sim: corruption past E2E's own timeout is lost communication too", function()
  local d = diag()
  clean(d)
  fault("bad_crc", 700)
  hold(500)
  check.dtc(d, "U0418-00", { testFailed = true, confirmedDTC = true })
  check.dtc(d, "U0121-00", { testFailed = true, confirmedDTC = true })
  hold(500)
end)

test("net sim: a short silence is a counter gap, not a timeout", function()
  local d = diag()
  clean(d)
  fault("drop", 80) -- one or two frames: a gap well inside E2E's 300 ms timeout
  hold(300)
  check.dtc(d, "U0418-01", { confirmedDTC = true })
  check.dtc(d, "U0121-00", { confirmedDTC = false })
  check.dtc(d, "U0418-00", { confirmedDTC = false })
end)

test("net sim: silence past E2E's own timeout is lost communication", function()
  local d = diag()
  clean(d)
  fault("drop", 700)
  hold(500)
  check.dtc(d, "U0121-00", { testFailed = true, confirmedDTC = true })
  hold(500) -- the sender is back
  check.dtc(d, "U0121-00", { testFailed = false, confirmedDTC = true })
end)

test("net sim: a frozen counter cannot keep the sender alive, and is not an integrity fault", function()
  local d = diag()
  clean(d)
  fault("freeze_counter", 700)
  hold(500)
  check.dtc(d, "U0121-00", { testFailed = true, confirmedDTC = true })
  check.dtc(d, "U0418-00", { confirmedDTC = false })
  hold(500)
end)

test("net sim: with DTC setting off (0x85) a fault records nothing; the session end restores it", function()
  local d = diag()
  clean(d)
  d:session(0x03)
  check.equal(tohex(d:raw("\x85\x02")), "C5 02")
  fault("bad_crc", 200)
  hold(400)
  check.dtc(d, "U0418-00", { confirmedDTC = false })
  d:session(0x01) -- back to default: DTC setting resumes
  fault("bad_crc", 200)
  hold(400)
  check.dtc(d, "U0418-00", { confirmedDTC = true })
  clean(d)
end)
