-- Receive status (docs/diagnostics.md §3.2): BrakePressure arrives E2E-protected in BrakeStatus
-- (0x301: bytes 0-1 raw kPa x0.1, CRC byte 4, counter low nibble of byte 5, data_id 0x44). The
-- bridge publishes its RxStatus and the E2E lost-frame count; BrakeMonitor echoes what it SEES on
-- BrakeReport (0x131, every 50 ms: byte 0 status, bytes 1-2 lost, little-endian).
-- never_received is the enum's zero value (pinned by tools/loom2v's rx status test): it is only on
-- the wire in the first 300 ms after start, before any script of this suite can run.
-- @verifies REQ-COM-008
local OK, TIMEOUT, INTEGRITY = 1, 2, 3


local ctr = 0
-- the next BrakeStatus in sequence; `skip` frames are left out first (a gap), `corrupt` breaks the CRC.
-- Stamped with blobly_net's AUTOSAR E2E Profile 1 (e2e.p01_protect), the profile the app checks.
local function brake(raw, skip, corrupt)
  ctr = (ctr + 1 + (skip or 0)) % 15 -- Profile 1 counts 0..14
  local f = e2e.p01_protect(string.char(raw & 0xFF, (raw >> 8) & 0xFF, 0, 0, 0, 0), 0x44, 4, 5, ctr)
  if corrupt then f = f:sub(1, 4) .. string.char(string.byte(f, 5) ~ 0xFF) .. f:sub(6) end
  bus.send("CAN1", 0x301, f)
end

-- the newest BrakeReport seen within `ms` (after dropping what was buffered before)
local function report(ms)
  while bus.recv("CAN1", 0) do end
  local last, t = nil, 0
  while t < ms do
    local f = bus.recv("CAN1", 10)
    if f and f.id == 0x131 then last = f.data end
    t = t + 10
  end
  check.truthy(last ~= nil, "no BrakeReport within " .. ms .. " ms")
  return string.byte(last, 1), string.byte(last, 2) + 256 * string.byte(last, 3)
end

test("RxStatus: a sender absent since start reaches timeout (the deadline runs from start)", function()
  local st = report(150) -- no script ever sends BrakeStatus before this one
  check.equal(st, TIMEOUT)
end)

test("RxStatus: good frames read ok, and a counter gap is counted as lost frames", function()
  for _ = 1, 5 do brake(1000); sleep_ms(10) end
  local st, lost0 = report(150)
  check.equal(st, OK)
  brake(1000, 2) -- two frames missing from the sequence
  sleep_ms(10)
  brake(1000)
  local st2, lost1 = report(150)
  check.equal(st2, OK)
  check.equal(lost1 - lost0, 2)
end)

test("RxStatus: a bad CRC reads integrity, silence then timeout, and a good frame ok again", function()
  brake(1000)
  brake(1000, 0, true)
  check.equal((report(150)), INTEGRITY) -- the E2E timeout still counts from the last VALID frame
  sleep_ms(300) -- silence is now the newer fact
  check.equal((report(150)), TIMEOUT)
  brake(1000)
  check.equal((report(150)), OK)
end)

test("RxStatus: frames missed while 0x28 has reception off are not counted as lost", function()
  local d = uds.open("CAN1", { tx = 0x101, rx = 0x102 })
  for _ = 1, 3 do brake(1000); sleep_ms(10) end
  local _, lost0 = report(150)
  d:session(0x03)
  check.equal(tohex(d:raw(fromhex("28 02 F1"))), "68 02") -- normal msgs: rx off, tx on
  brake(1000, 3) -- a gap of three while reception is off
  sleep_ms(20)
  check.equal(tohex(d:raw(fromhex("28 00 F1"))), "68 00")
  brake(1000)
  local st, lost1 = report(150)
  check.equal(st, OK)
  check.equal(lost1, lost0, "commanded silence was counted as lost frames")
  d:session(0x01)
end)

test("RxStatus: a gap spanning 0x28 rx-off with no frame during it is not counted as lost", function()
  local d = uds.open("CAN1", { tx = 0x101, rx = 0x102 })
  for _ = 1, 3 do brake(1000); sleep_ms(10) end
  local _, lost0 = report(150)
  d:session(0x03)
  check.equal(tohex(d:raw(fromhex("28 02 F1"))), "68 02")
  sleep_ms(50) -- nothing sent while reception is off
  check.equal(tohex(d:raw(fromhex("28 00 F1"))), "68 00")
  brake(1000, 4) -- the first frame after re-enable closes a gap of four
  local st, lost1 = report(150)
  check.equal(st, OK)
  check.equal(lost1, lost0, "the gap spanning commanded silence was counted as lost")
  brake(1000, 1) -- a real gap after that still counts
  check.equal(select(2, report(150)), lost0 + 1)
  d:session(0x01)
end)

test("RxStatus: rx switched off and on inside one drain still hides the gap spanning it", function()
  local d = uds.open("CAN1", { tx = 0x101, rx = 0x102 })
  for _ = 1, 3 do brake(1000); sleep_ms(10) end
  local _, lost0 = report(150)
  d:session(0x03)
  -- two suppressed FUNCTIONAL 0x28s back to back: rx off, then on again, in one bridge drain
  bus.send("CAN1", 0x7DF, fromhex("03 28 82 F1 00 00 00 00"))
  bus.send("CAN1", 0x7DF, fromhex("03 28 80 F1 00 00 00 00"))
  sleep_ms(30)
  brake(1000, 3)
  local st, lost1 = report(150)
  check.equal(st, OK)
  check.equal(lost1, lost0, "a gap spanning an in-drain rx-off was counted as lost")
  d:session(0x01)
end)

test("RxStatus: rx switched off and on inside one drain restarts the deadline", function()
  local d = uds.open("CAN1", { tx = 0x101, rx = 0x102 })
  d:session(0x03)
  for _ = 1, 3 do brake(1000); sleep_ms(10) end
  sleep_ms(250) -- most of the 300 ms deadline gone
  -- rx off and on again in one bridge drain, with NO frame between (a valid one would refresh
  -- the E2E timeout by itself and hide a missing restart)
  bus.send("CAN1", 0x7DF, fromhex("03 28 82 F1 00 00 00 00"))
  bus.send("CAN1", 0x7DF, fromhex("03 28 80 F1 00 00 00 00"))
  -- without a restart the old deadline fires at ~300 ms and is reported by ~360 ms; restarted
  -- at ~255 ms, it runs to ~555 ms — so read between ~375 and ~475 ms
  sleep_ms(120)
  check.equal((report(100)), OK, "the deadline was not restarted when reception returned")
  d:session(0x01)
end)

test("RxStatus: a stuck sender repeating one frame runs out E2E's own timeout (REQ-E2E-002)", function()
  brake(1000)
  check.equal((report(150)), OK)
  for _ = 1, 20 do brake(1000, -1); sleep_ms(20) end -- the SAME counter again: repeats, not valid
  check.equal((report(100)), TIMEOUT, "repeated frames kept a stuck sender alive")
  brake(1000)
  check.equal((report(150)), OK)
end)

test("RxStatus: integrity after the timeout has fired gives way to timeout again", function()
  brake(1000)
  sleep_ms(400) -- the E2E timeout fires
  check.equal((report(100)), TIMEOUT)
  brake(1000, 0, true) -- one corrupt frame
  check.equal((report(100)), INTEGRITY)
  sleep_ms(300) -- silence after it is the newer fact again
  check.equal((report(150)), TIMEOUT, "integrity stuck after an already-fired timeout")
  brake(1000)
  check.equal((report(150)), OK)
end)

test("RxStatus: a valid frame right after rx is re-enabled is not judged late by the stale deadline", function()
  local d = uds.open("CAN1", { tx = 0x101, rx = 0x102 })
  brake(1000)
  d:session(0x03)
  check.equal(tohex(d:raw(fromhex("28 02 F1"))), "68 02") -- rx off
  sleep_ms(400) -- longer than the 300 ms timeout, silence commanded
  -- rx on (suppressed functional request) and a valid frame, in one bridge drain
  bus.send("CAN1", 0x7DF, fromhex("03 28 80 F1 00 00 00 00"))
  brake(1000)
  check.equal((report(100)), OK, "commanded silence reported as a sender timeout")
  d:session(0x01)
end)
