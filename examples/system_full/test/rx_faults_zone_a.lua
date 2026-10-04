-- @project rx_faults.blobnet
-- @verifies REQ-COM-008 REQ-DIAG-011
-- The receive checks on a TARGET (docs/diagnostics.md R5): zone_a (H723, the edge bus) checks the
-- chassis node's SafetyCmdFrame on its ThreadX comm thread — AUTOSAR E2E Profile 1 and E2E's own
-- 300 ms sender-loss timeout, from edge.dbc — and its FB SafetyMonitor reads the value WITH its
-- receive status and lost count, holding the safe level 0 unless the status is ok. What the FB saw
-- comes back on SafetyViewFrame (0x134: byte 0 status, byte 1 lost count, bytes 2-3 the level it acts
-- on). Three signal-status faults turn the receive status into DTCs with no FB code:
--   U0164-00  SafetyCmdTimeout    no valid frame for 300 ms (silence, corruption, a stuck counter)
--   U0464-00  SafetyCmdIntegrity  a frame failed its CRC
--   U0464-01  SafetyCmdLost       the E2E counter skipped (frames lost in between)
-- blobly_net simulates the chassis (rx_faults.blobnet) and breaks it with sim.fault, so nothing here
-- is hand-stamped. The operation cycle is zone_a's power cycle, so a confirmed DTC stays confirmed
-- until cleared; each test starts from 0x14. SafetyCmdFrame runs every 50 ms. Bench only (the
-- flashed board on the CANsub, edge = channel 1):
--   BLOBLY_NET=/path/to/blobly_net; v -enable-globals -path "@vlib|@vmodules|$BLOBLY_NET/modules" \
--     run $BLOBLY_NET/cmd/script/run.v examples/system_full/test/rx_faults_zone_a.lua

local OK, TIMEOUT, INTEGRITY = 1, 2, 3
local SAFE = { "U0164-00", "U0464-00", "U0464-01" }
local LEVEL = 500 -- the simulated chassis's command (rx_faults.blobnet)

local function diag() return uds.open("edge", { tx = 0x7C0, rx = 0x7C8 }) end
local function fault(kind, ms) sim.fault("edge", "chassis", "SafetyCmdFrame", kind, ms) end

-- every SafetyView zone_a sends within `ms`: { status, lost, level } each
local function views(ms)
  while bus.recv("edge", 0) do end
  local out, t = {}, 0
  while t < ms do
    local f = bus.recv("edge", 10)
    if f and f.id == 0x134 then
      local b = { string.byte(f.data, 1, 4) }
      out[#out + 1] = { status = b[1], lost = b[2], level = b[3] + 256 * b[4] }
    end
    t = t + 10
  end
  check.truthy(#out > 0, "no SafetyView within " .. ms .. " ms")
  return out
end

local function last(ms) local v = views(ms); return v[#v] end

-- a clean slate: cleared, then long enough for a healthy sender to pass every test again
local function clean(d)
  sleep_ms(400)
  d:clear_dtcs()
  sleep_ms(400)
  for _, n in ipairs(SAFE) do
    check.dtc(d, n, { testFailed = false, confirmedDTC = false, testFailedSinceLastClear = false })
  end
end

test("zone_a rx: a healthy chassis reaches the FB as ok and keeps every safety DTC clear", function()
  local d = diag()
  clean(d)
  local v = last(500)
  check.equal(v.status, OK, "the FB's view of SafetyCmd's status")
  check.equal(v.level, LEVEL, "the level the FB acts on")
  for _, n in ipairs(SAFE) do check.dtc(d, n, { testFailed = false, confirmedDTC = false }) end
end)

test("zone_a rx: a corrupt CRC is an integrity fault, and the FB holds the safe level", function()
  local d = diag()
  clean(d)
  fault("bad_crc", 700) -- past the 300 ms timeout: no valid frame, so lost communication too
  local seen = views(600)
  local held = true
  for _, v in ipairs(seen) do
    if v.status == OK or v.level ~= 0 then held = false end
  end
  check.truthy(held, "the FB acted on a corrupt command")
  check.dtc(d, "U0464-00", { testFailed = true, confirmedDTC = true })
  check.dtc(d, "U0164-00", { testFailed = true, confirmedDTC = true })
  local v = last(600) -- the sender is good again
  check.equal(v.status, OK)
  check.equal(v.level, LEVEL)
  check.dtc(d, "U0464-00", { testFailed = false, confirmedDTC = true })
  check.dtc(d, "U0164-00", { testFailed = false, confirmedDTC = true })
end)

test("zone_a rx: a short gap is a lost-frame fault, counted where the FB sees it", function()
  local d = diag()
  clean(d)
  local before = last(300).lost
  fault("drop", 80) -- one or two frames: a gap well inside the 300 ms timeout
  local v = last(400)
  check.equal(v.status, OK)
  check.truthy((v.lost - before) % 256 >= 1, "the FB saw no lost frame (before " .. before .. ", now " .. v.lost .. ")")
  check.dtc(d, "U0464-01", { confirmedDTC = true })
  check.dtc(d, "U0164-00", { confirmedDTC = false })
  check.dtc(d, "U0464-00", { confirmedDTC = false })
end)

test("zone_a rx: silence past E2E's own timeout is lost communication, read by the FB", function()
  local d = diag()
  clean(d)
  fault("drop", 900)
  sleep_ms(400) -- the timeout has run out
  local v = last(300)
  check.equal(v.status, TIMEOUT, "the FB's view during the silence")
  check.equal(v.level, 0, "the FB acted on a stale command")
  check.dtc(d, "U0164-00", { testFailed = true, confirmedDTC = true })
  sleep_ms(400) -- the sender is back
  check.equal(last(300).status, OK)
  check.dtc(d, "U0164-00", { testFailed = false, confirmedDTC = true })
end)

test("zone_a rx: a frozen counter cannot keep the sender alive, and is not an integrity fault", function()
  local d = diag()
  clean(d)
  fault("freeze_counter", 700)
  sleep_ms(500)
  check.dtc(d, "U0164-00", { testFailed = true, confirmedDTC = true })
  check.dtc(d, "U0464-00", { confirmedDTC = false })
  sleep_ms(500)
end)

-- REQ-DIAG-011: no result is recorded while CommunicationControl has reception off — the silence it
-- commands is not a lost sender, and the frames the sender went on with are not lost frames
test("zone_a rx: with 0x28 reception off a silence records nothing, nor does the gap it spans", function()
  local d = diag()
  clean(d)
  d:session(0x03)
  check.equal(tohex(d:raw("\x28\x02\x01")), "68 02") -- disableRxAndEnableTx, normal messages
  fault("drop", 700) -- the sender stops too: past the timeout, while reception is off
  sleep_ms(900)
  check.equal(tohex(d:raw("\x28\x00\x01")), "68 00") -- enableRxAndTx
  sleep_ms(400)
  check.equal(last(300).status, OK)
  for _, n in ipairs(SAFE) do check.dtc(d, n, { confirmedDTC = false, testFailedSinceLastClear = false }) end
  d:session(0x01)
end)

test("zone_a rx: with DTC setting off (0x85) a broken sender records nothing", function()
  local d = diag()
  clean(d)
  d:session(0x03)
  d:dtc_setting(false)
  fault("bad_crc", 700)
  sleep_ms(900)
  for _, n in ipairs(SAFE) do check.dtc(d, n, { confirmedDTC = false }) end
  d:dtc_setting(true)
  d:session(0x01)
end)
