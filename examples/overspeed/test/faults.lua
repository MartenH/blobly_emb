-- Faults (docs/diagnostics.md §3.3): EngineMonitor reports EngineOverRev (> 6000 rpm) each
-- dispatch; the Loom debounces it on the ctrl thread (3 results); the fault memory on the
-- diagnostic bridge keeps DTC 0x021900's ISO 14229-1 status, read and cleared with raw 0x19 / 0x14
-- / 0x85. The operation cycle is IgnitionOn (frame 0x302), also the fault's enable condition.
-- (REQ-DIAG-009 / 010 are verified by comm/fault's unit tests; this proves the generated wiring end to end.)
-- @verifies REQ-DIAG-011
local function diag() return uds.open("CAN1", { tx = 0x101, rx = 0x102 }) end
-- Ignition is cyclic (500 ms deadline): every helper keeps sending the current state
local ign = false
local function ign_frame() bus.send("CAN1", 0x302, string.char(ign and 1 or 0)) end
local function ignition(on) ign = on; ign_frame(); sleep_ms(40) end
local function rpm(v, ms, quiet_ignition)
  local t = 0
  while t < ms do
    bus.send_message("CAN1", "Powertrain", { EngineSpeed = v })
    if not quiet_ignition then ign_frame() end
    sleep_ms(10); t = t + 10
  end
  sleep_ms(40) -- the FB, the debounce and the bridge each run every 10 ms
  if not quiet_ignition then ign_frame() end
end
-- 0x19 02 with mask 0x09 (testFailed | confirmed): the hex of the DTC records, or "" for none.
-- EngineOverRev (0x021900) is declared first; EngineIdleLow (0x050600, < 400 rpm, no enable
-- condition — only the operation cycle gates it) second.
-- Only the two ENGINE DTCs count here: the brake signal faults further down watch a sender these
-- tests leave silent, so their DTCs are legitimately set meanwhile.
local function failing(d)
  local r = d:raw(fromhex("19 02 09"))
  check.equal(tohex(r:sub(1, 3)), "59 02 7F")
  local out = {}
  for i = 4, #r - 3, 4 do
    local rec = tohex(r:sub(i, i + 3))
    if rec:sub(1, 8) == "02 19 00" or rec:sub(1, 8) == "05 06 00" then out[#out + 1] = rec end
  end
  return table.concat(out, " ")
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
  rpm(100, 100) -- EngineIdleLow fails and has no enable condition: only the cycle can stop it
  check.equal(failing(d), "")
  rpm(3000, 60)
end)

test("Faults: an over-rev in a cycle confirms the DTC; passing clears testFailed", function()
  local d = diag()
  ignition(true)
  rpm(7000, 100)
  check.equal(failing(d), "02 19 00 2F") -- TF | TFTOC | pending | confirmed | TFSLC
  -- 0x19 01 counts every DTC matching the mask — the brake signal faults' DTCs included (their
  -- sender is silent here), so only the shape and a lower bound are this test's to check
  local cnt = d:raw(fromhex("19 01 09"))
  check.equal(tohex(cnt:sub(1, 4)), "59 01 7F 01")
  check.truthy(string.byte(cnt, 5) * 256 + string.byte(cnt, 6) >= 1)
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

test("Faults: an ignition off/on pair drained in one pass is two cycle edges", function()
  local d = diag()
  rpm(7000, 100)
  check.equal(status(d) & 0x02, 0x02) -- failed this cycle
  rpm(3000, 60)
  bus.send("CAN1", 0x302, string.char(0)) -- off and on back to back: one bridge pass
  bus.send("CAN1", 0x302, string.char(1))
  sleep_ms(40)
  check.equal(status(d) & 0x02, 0, "the new cycle did not start: testFailedThisOperationCycle carried over")
  d:raw(fromhex("14 FF FF FF"))
  rpm(3000, 60)
end)

test("Faults: the ignition frame going silent ends the operation cycle (its deadline)", function()
  local d = diag()
  ignition(true)
  d:raw(fromhex("14 FF FF FF"))
  rpm(3000, 60)
  rpm(3000, 700, true) -- no Ignition frames: the 500 ms deadline publishes it off
  rpm(100, 100, true)  -- EngineIdleLow fails (no enable condition): outside a cycle, not recorded
  check.equal(failing(d), "", "recorded after the cycle signal timed out")
  ignition(true)
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

-- Signal-status faults on BrakePressure (frame 0x301, E2E: data_id 0x44, CRC byte 4, counter low
-- nibble of byte 5, its own 300 ms timeout) — raised by the bridge, no FB code.
local function crc8(bytes)
  local crc = 0xFF
  for _, b in ipairs(bytes) do
    crc = crc ~ b
    for _ = 1, 8 do
      if crc & 0x80 ~= 0 then crc = ((crc << 1) ~ 0x1D) & 0xFF else crc = (crc << 1) & 0xFF end
    end
  end
  return crc ~ 0xFF
end
local ctr = 0
local function brake(skip, corrupt)
  ctr = (ctr + 1 + (skip or 0)) & 0x0F
  local d = { 0xE8, 0x03, 0, 0, 0, ctr }
  local b = { 0x44, 0x00 }
  for i = 0, 5 do if i ~= 4 then b[#b + 1] = d[i + 1] end end
  d[5] = crc8(b)
  if corrupt then d[5] = d[5] ~ 0xFF end
  bus.send("CAN1", 0x301, string.char(table.unpack(d)))
end
local function brakes(n) for _ = 1, n do brake(); ign_frame(); sleep_ms(10) end; sleep_ms(30) end
-- the status byte of `dtc` (3-byte hex string) from 0x19 0A
local function dtc(d, hex)
  local r = d:raw(fromhex("19 0A"))
  for i = 4, #r - 3, 4 do
    if tohex(r:sub(i, i + 2)) == hex then return string.byte(r, i + 3) end
  end
  error("DTC " .. hex .. " not listed")
end

test("Signal faults: brake frame silence, corruption and a gap each raise their own DTC", function()
  local d = diag()
  ignition(true)
  brakes(10) -- a healthy sender
  d:raw(fromhex("14 FF FF FF"))
  brakes(10)
  check.equal(dtc(d, "C1 21 00") & 0x09, 0, "timeout DTC set while frames flowed")
  check.equal(dtc(d, "C4 18 00") & 0x09, 0)
  check.equal(dtc(d, "C4 18 01") & 0x09, 0)
  rpm(3000, 400) -- no brake frames: E2E's own 300 ms timeout runs out
  check.equal(dtc(d, "C1 21 00") & 0x09, 0x09, "no timeout DTC after the brake frames stopped")
  brakes(10)
  check.equal(dtc(d, "C1 21 00") & 0x01, 0, "testFailed stayed after the sender came back")
  brake(0, true); sleep_ms(40) -- one corrupt frame
  check.equal(dtc(d, "C4 18 00") & 0x09, 0x09, "no integrity DTC for a corrupt frame")
  brakes(3)
  d:raw(fromhex("14 C4 18 01")) -- the corrupt frame also counted as lost: start the gap check clean
  brakes(3)
  check.equal(dtc(d, "C4 18 01") & 0x28, 0, "lost DTC set before any gap")
  brake(2); sleep_ms(40) -- two frames missing
  -- a gap is an event: it fails the one pass that sees it, and the next good frame passes again —
  -- so the DTC is confirmed (and failed since clear), not currently failed
  check.equal(dtc(d, "C4 18 01") & 0x28, 0x28, "no lost DTC for a gap")
  brakes(5)
  d:raw(fromhex("14 FF FF FF"))
  rpm(3000, 60)
end)

test("Signal faults: a corrupt frame followed by a good one in the same pass is still an integrity event", function()
  local d = diag()
  ignition(true)
  brakes(5)
  d:raw(fromhex("14 C4 18 00"))
  brakes(3)
  brake(0, true) -- corrupt ...
  brake()        -- ... and good, back to back: one bridge drain, the good status is the last one
  sleep_ms(40)
  check.equal(dtc(d, "C4 18 00") & 0x28, 0x28, "an integrity event overwritten within one pass was lost")
  brakes(5)
  d:raw(fromhex("14 FF FF FF"))
  rpm(3000, 60)
end)

test("Signal faults: an event and the cycle ending in the same pass is recorded in that cycle", function()
  local d = diag()
  ignition(true)
  brakes(5)
  d:raw(fromhex("14 C4 18 00"))
  brakes(3)
  brake(0, true)                                   -- a corrupt frame ...
  ign = false; ign_frame()                         -- ... and the ignition going off, one drain
  sleep_ms(40)
  check.equal(dtc(d, "C4 18 00") & 0x20, 0x20, "an event in the pass that ended the cycle was lost")
  ignition(true)
  brakes(5)
  d:raw(fromhex("14 FF FF FF"))
  rpm(3000, 60)
end)

test("Signal faults: a status that went stale during 0x28 rx-off does not re-qualify at re-enable", function()
  local d = diag()
  ignition(true)
  brakes(5)
  rpm(3000, 400) -- the brake frames stop: timeout
  check.equal(dtc(d, "C1 21 00") & 0x01, 0x01)
  d:session(0x03)
  check.equal(tohex(d:raw(fromhex("28 02 F1"))), "68 02") -- rx off
  d:raw(fromhex("14 C1 21 00"))
  check.equal(tohex(d:raw(fromhex("28 00 F1"))), "68 00") -- rx on: the sender is back at once
  brakes(5)
  check.equal(dtc(d, "C1 21 00") & 0x09, 0, "a timeout from before the pause re-qualified")
  d:session(0x01)
  d:raw(fromhex("14 FF FF FF"))
  rpm(3000, 60)
end)
