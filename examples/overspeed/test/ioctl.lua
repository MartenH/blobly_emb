-- InputOutputControlByIdentifier (0x2F) on vcan0 (docs/diagnostics.md §3.1 "Input/output control"):
-- WarnLamp's DID 0xF1B0 carries a control, so a tester overrides the lamp LampFrame (0x110: byte0
-- WarnLamp, byte1 E2E CRC, byte2 counter) carries — where the bridge encodes the frame, never inside
-- LampController, which keeps computing its own. Extended session (S3 = 2 s), no 0x27 level, every
-- parameter. LampFrame is mixed (100 ms heartbeat, 20 ms min_delay), so a control that changes the
-- payload goes out at once, and E2E stamps the frame after the substitution.
-- Not tagged: comm/uds, comm/diag and tools/loom2v io_control_test.v verify REQ-DIAG-100..107 in CI;
-- this is their on-bus evidence.
local CH, LAMP, DID = "CAN1", 0x110, 0xF1B0

local function diag()
  return uds.open(CH, { tx = 0x101, rx = 0x102 })
end

local function lamp_of(f)
  return string.byte(f.data, 1) & 1
end

local function crc_ok(f)
  return string.byte(f.data, 2) == e2e.p01_crc(f.data:sub(1, 3), 0x10, 1, 2)
end

-- the first LampFrame whose lamp is `want` within `timeout_ms`, and how long after `t0` it came
local function lamp_becomes(want, t0, timeout_ms)
  local deadline = now_ms() + timeout_ms
  while now_ms() < deadline do
    local f = bus.recv(CH, 10)
    if f and f.id == LAMP and lamp_of(f) == want then
      return f, f.t_ms - t0
    end
  end
  return nil, nil
end

-- the next `n` LampFrames' lamps, after the queue is drained
local function lamps(n)
  while bus.recv(CH, 0) do end
  local out = {}
  for i = 1, n do
    out[i] = lamp_of(expect(CH, LAMP, 300))
  end
  return out
end

local function all_lamps(n, want, what)
  for _, l in ipairs(lamps(n)) do
    check.equal(l, want, what)
  end
end

-- no Powertrain on the bus: the receive deadlines have expired, so LampController says off
local function idle()
  sleep_ms(500)
  all_lamps(3, 0, "the FB's lamp, nothing driven")
end

-- a heartbeat just went: the next one is ~100 ms away, so a frame within ~60 ms is the immediate send
local function after_a_heartbeat()
  while bus.recv(CH, 0) do end
  expect(CH, LAMP, 300)
  return now_ms()
end

test("0x2F: not in the default session", function()
  local d = diag()
  d:session(0x01)
  check.nrc(0x7F, function() d:io_control(DID, 3, "\x01") end)
end)

test("0x2F 03: the lamp goes on at once, protected, and the DID reads it", function()
  idle()
  local d = diag()
  d:session(0x03)
  local t0 = after_a_heartbeat()
  check.equal(d:io_control(DID, 3, "\x01"), "\x01")
  local f, dt = lamp_becomes(1, t0, 300)
  check.truthy(f ~= nil, "the lamp never went on")
  check.truthy(dt < 60, "sent " .. dt .. " ms after the request: the heartbeat, not the change")
  local frames, prev = {}, nil
  while #frames < 4 do
    local g = expect(CH, LAMP, 300)
    frames[#frames + 1] = g
  end
  for _, g in ipairs(frames) do
    check.equal(lamp_of(g), 1, "under control")
    check.truthy(crc_ok(g), "the E2E CRC is stamped over the controlled value")
    local ctr = string.byte(g.data, 3) & 0x0F
    if prev then check.truthy(ctr ~= prev, "the alive counter advances") end
    prev = ctr
  end
  check.equal(d:read_did(DID), "\x01")
  check.nrc(0x31, function() d:io_control(DID, 3, "\x02") end) -- a bool: 0 or 1
  check.nrc(0x13, function() d:raw("\x2F\xF1\xB0\x03") end) -- 03 without its state
  check.nrc(0x31, function() d:raw("\x2F\xF1\xB0\x04") end) -- no such parameter (raw: the client refuses one above 03)
  -- 00: the FB's lamp, off, goes out at once too (a real change of the payload)
  t0 = after_a_heartbeat()
  check.equal(d:io_control(DID, 0), "\x00")
  local h, dt2 = lamp_becomes(0, t0, 300)
  check.truthy(h ~= nil, "the lamp never went off")
  check.truthy(dt2 < 60, "returned " .. dt2 .. " ms after the request: the heartbeat, not the change")
  d:session(0x01)
end)

test("0x2F 02 freezes the lamp while the FB turns it on; 00 gives the FB's back", function()
  idle()
  local d = diag()
  d:session(0x03)
  check.equal(d:io_control(DID, 2), "\x00")
  for _ = 1, 150 do -- 1.5 s over 120 km/h: the FB's filter converges and it says on
    bus.send_message(CH, "Powertrain", { VehicleSpeed = 150 })
    sleep_ms(10)
    local f = bus.recv(CH, 0)
    while f do
      if f.id == LAMP then check.equal(lamp_of(f), 0, "frozen") end
      f = bus.recv(CH, 0)
    end
  end
  check.equal(d:read_did(DID), "\x00")
  bus.send_message(CH, "Powertrain", { VehicleSpeed = 150 })
  local t0 = now_ms()
  check.equal(d:io_control(DID, 0), "\x01") -- the FB's lamp: on
  local on = false
  for _ = 1, 30 do
    bus.send_message(CH, "Powertrain", { VehicleSpeed = 150 })
    if lamp_becomes(1, t0, 10) then
      on = true
      break
    end
  end
  check.truthy(on, "the FB's lamp did not come back")
  d:session(0x01)
end)

-- Powertrain held over 120 km/h: the first LampFrame whose lamp is `want` within `timeout_ms`
local function drive_until(want, timeout_ms)
  local deadline = now_ms() + timeout_ms
  while now_ms() < deadline do
    bus.send_message(CH, "Powertrain", { VehicleSpeed = 150 })
    local f = bus.recv(CH, 10)
    while f do
      if f.id == LAMP and lamp_of(f) == want then return f end
      f = bus.recv(CH, 0)
    end
  end
  return nil
end

test("0x2F 01 holds the initial value while the FB says on; 00 gives the FB's back", function()
  idle()
  local d = diag()
  d:session(0x03)
  check.truthy(drive_until(1, 3000) ~= nil, "the FB's lamp never went on")
  check.equal(d:read_did(DID), "\x01") -- the FB's on, published
  check.equal(d:io_control(DID, 1), "\x00") -- WarnLamp's initial value: off
  while bus.recv(CH, 0) do end -- what went before the request
  local n, deadline = 0, now_ms() + 500
  while now_ms() < deadline do -- the FB keeps saying on
    bus.send_message(CH, "Powertrain", { VehicleSpeed = 150 })
    local f = bus.recv(CH, 10)
    while f do
      if f.id == LAMP then
        check.equal(lamp_of(f), 0, "reset to default while the FB says on")
        n = n + 1
      end
      f = bus.recv(CH, 0)
    end
  end
  check.truthy(n >= 3, "only " .. n .. " LampFrames in 500 ms")
  check.equal(d:read_did(DID), "\x00")
  bus.send_message(CH, "Powertrain", { VehicleSpeed = 150 })
  check.equal(d:io_control(DID, 0), "\x01") -- the FB's lamp: on
  check.truthy(drive_until(1, 300) ~= nil, "the FB's lamp did not come back")
  d:session(0x01)
end)

test("0x2F: a return to default, S3 and an ECUReset each return control", function()
  idle()
  local d = diag()
  d:session(0x03)
  d:io_control(DID, 3, "\x01")
  all_lamps(2, 1, "under control")
  d:session(0x01)
  all_lamps(3, 0, "0x10 01 returned control")
  d:session(0x03)
  d:io_control(DID, 3, "\x01")
  all_lamps(2, 1, "under control")
  sleep_ms(2500) -- s3_ms = 2000, nothing sent
  all_lamps(3, 0, "S3 returned control")
  check.equal(d:read_did(DID), "\x00")
  d:session(0x03)
  d:io_control(DID, 3, "\x01")
  all_lamps(2, 1, "under control")
  check.equal(tohex(d:reset(1)), "01")
  sleep_ms(100)
  all_lamps(3, 0, "the ECUReset returned control")
end)

test("0x2F: a functional request is ignored", function()
  idle()
  local d = diag()
  d:session(0x03)
  while bus.recv(CH, 0) do end
  bus.send(CH, 0x7DF, "\x05\x2F\xF1\xB0\x03\x01\x00\x00")
  sleep_ms(100)
  local f = bus.recv(CH, 0)
  while f do
    check.truthy(f.id ~= 0x102, "a functional 0x2F was answered: " .. tohex(f.data))
    if f.id == LAMP then check.equal(lamp_of(f), 0, "a functional 0x2F took control") end
    f = bus.recv(CH, 0)
  end
  d:session(0x01)
end)
