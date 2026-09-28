-- Faults (docs/diagnostics.md §3.3): EngineMonitor reports EngineOverRev (> 6000 rpm) each
-- dispatch; the Loom debounces it on the ctrl thread (3 results); the fault memory on the
-- diagnostic bridge keeps DTC 0x021900's ISO 14229-1 status, read and cleared with raw 0x19 / 0x14
-- / 0x85. The operation cycle is IgnitionOn (frame 0x302), also the fault's enable condition.
-- (REQ-DIAG-009 / 010 are verified by comm/fault's unit tests; this proves the generated wiring end to end.)
local function diag() return uds.open("CAN1", { tx = 0x101, rx = 0x102 }) end
local function ignition(on) bus.send("CAN1", 0x302, string.char(on and 1 or 0)); sleep_ms(40) end
local function rpm(v, ms)
  local t = 0
  while t < ms do bus.send_message("CAN1", "Powertrain", { EngineSpeed = v }); sleep_ms(10); t = t + 10 end
  sleep_ms(40) -- the FB, the debounce and the bridge each run every 10 ms
end
-- 0x19 02 with mask 0x09 (testFailed | confirmed): the hex of the DTC records, or "" for none
local function failing(d)
  local r = d:raw(fromhex("19 02 09"))
  check.equal(tohex(r:sub(1, 3)), "59 02 7F")
  return tohex(r:sub(4))
end
local function status(d)
  local r = d:raw(fromhex("19 0A"))
  check.equal(tohex(r:sub(4, 6)), "02 19 00")
  return string.byte(r, 7)
end

test("Faults: outside an operation cycle nothing is recorded", function()
  local d = diag()
  ignition(false)
  d:raw(fromhex("14 FF FF FF"))
  rpm(7000, 100)
  check.equal(failing(d), "")
end)

test("Faults: an over-rev in a cycle confirms the DTC; passing clears testFailed", function()
  local d = diag()
  ignition(true)
  rpm(7000, 100)
  check.equal(failing(d), "02 19 00 2F") -- TF | TFTOC | pending | confirmed | TFSLC
  check.equal(tohex(d:raw(fromhex("19 01 09"))), "59 01 7F 01 00 01")
  rpm(3000, 100)
  check.equal(status(d), 0x2E, "testFailed should drop once the test passes")
end)

test("Faults: 0x14 clears the DTC, and a new over-rev is recorded again", function()
  local d = diag()
  check.equal(tohex(d:raw(fromhex("14 FF FF FF"))), "54")
  check.nrc(0x31, function() d:raw(fromhex("14 12 34 56")) end)
  rpm(3000, 60)
  check.equal(failing(d), "", "a cleared DTC came back without a new failure")
  rpm(7000, 100)
  check.equal(failing(d), "02 19 00 2F")
  d:raw(fromhex("14 FF FF FF"))
  rpm(3000, 60)
end)

test("Faults: 0x85 off records nothing; the session ending turns it back on", function()
  local d = diag()
  check.nrc(0x7F, function() d:raw(fromhex("85 02")) end) -- extended only
  d:session(0x03)
  check.equal(tohex(d:raw(fromhex("85 02"))), "C5 02")
  rpm(7000, 100)
  check.equal(failing(d), "", "recorded while DTC setting was off")
  d:session(0x01) -- back to default: DTC setting resumes
  rpm(3000, 60)
  rpm(7000, 100)
  check.equal(failing(d), "02 19 00 2F")
  d:raw(fromhex("14 FF FF FF"))
  rpm(3000, 60)
end)

test("Faults: a confirmed DTC ages out after two passing operation cycles", function()
  local d = diag()
  rpm(7000, 100) -- confirmed in this cycle
  rpm(3000, 60)
  check.equal(status(d) & 0x08, 0x08)
  for _ = 1, 2 do
    ignition(false); ignition(true) -- a new cycle ...
    rpm(3000, 60)                   -- ... tested and passed
  end
  ignition(false) -- the second passing cycle ends: aging = 2
  check.equal(status(d) & 0x0C, 0, "pending / confirmed survived two passing cycles")
end)
