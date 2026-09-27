-- UDS (ISO 14229) over ISO-TP on vcan0: drive the diag connection (Request 0x101
-- -> Response 0x102) with blobly_net's UDS client. Exercises the service dispatch
-- AND multi-frame segmentation (the 19-byte and 20-byte DIDs span several frames).
-- @verifies REQ-DIAG-002 REQ-DIAG-003 REQ-DIAG-004 REQ-DIAG-005 REQ-DIAG-006 REQ-DIAG-007
-- (the 0xF1A0 test injects VehicleSpeed=100 on the bus then reads the live DID back
--  through UDS and asserts ~100 — the DID returns the current signal value from the
--  same source the application sees. NOT REQ-NVM-008: 0xF1AA is a plain RAM cell, not
--  a persistent-storage binding — that requirement needs a DID bound to a persisted
--  signal, which no example wires yet.)
local function diag()
  return uds.open("CAN1", { tx = 0x101, rx = 0x102 })
end

test("UDS: tester present + session control", function()
  local d = diag()
  d:tester_present()        -- 0x3E -> 0x7E (raises on anything else)
  local params = d:session(0x03) -- 0x10 -> 0x50, returns P2/P2* timing
  check.truthy(#params >= 4, "session returned timing params")
end)

test("UDS: read DID 0xF190 constant (multi-frame response)", function()
  check.equal(diag():read_did(0xF190), "BLOBLY-OVERSPEED-01")
end)

test("UDS: read DID 0xF1A0 = live VehicleSpeed signal", function()
  -- hold a speed so the bridge has a fresh value, then read it back via diag
  for _ = 1, 25 do
    bus.send_message("CAN1", "Powertrain", { VehicleSpeed = 100 })
    sleep_ms(10)
  end
  local v = diag():read_did(0xF1A0) -- 2 bytes, big-endian km/h
  local kph = string.byte(v, 1) * 256 + string.byte(v, 2)
  check.truthy(kph >= 90 and kph <= 110, "diag read VehicleSpeed ~100, got " .. tostring(kph))
end)

test("UDS: write + read DID 0xF1AA (RAM, multi-frame both ways)", function()
  local d = diag()
  local payload = string.rep("Z", 20)
  d:write_did(0xF1AA, payload) -- 0x2E, 23-byte request -> FF/CF
  check.equal(d:read_did(0xF1AA), payload) -- 0x22, 23-byte response -> FF/CF
end)

-- R1 (docs/diagnostics.md): the server's session model, gating, multi-DID reads, functional
-- requests, ECUReset and CommunicationControl, over the real bus. Built on the client's raw()
-- plus raw frames, so it needs nothing beyond what blobly_net already offers.

-- bus.recv returns frames buffered since the channel opened: drain them before measuring, or a
-- test counts frames sent before the state it is checking (and leaves its own for the next test).
local function drain()
  while bus.recv("CAN1", 30) do end
end

test("UDS: several DIDs in one 0x22, in request order, unknown ones skipped", function()
  local d = diag()
  d:write_did(0xF1AA, fromhex("12 34"))
  local r = d:raw(fromhex("22 F1 AA 00 01 F1 90"))
  check.equal(tohex(r:sub(1, 5)), "62 F1 AA 12 34")
  check.equal(tohex(r:sub(6, 7)), "F1 90")
  check.equal(r:sub(8), "BLOBLY-OVERSPEED-01")
  check.nrc(0x31, function() d:raw(fromhex("22 00 01 00 02")) end)
end)

test("UDS: a DID writable only in extended is refused in default, accepted in extended", function()
  local d = diag()
  d:session(0x01)
  check.nrc(0x31, function() d:write_did(0xF1AB, fromhex("5A")) end)
  d:session(0x03)
  d:write_did(0xF1AB, fromhex("5A"))
  check.equal(tohex(d:read_did(0xF1AB)), "5A")
  d:session(0x01)
end)

test("UDS: 0x28 is gated to non-default sessions and silences application frames", function()
  local d = diag()
  d:session(0x01)
  check.nrc(0x7F, function() d:raw(fromhex("28 01 01")) end)
  d:session(0x03)
  check.equal(tohex(d:raw(fromhex("28 01 01"))), "68 01") -- normal msgs: rx on, tx off
  sleep_ms(50) -- a frame already in the controller's tx FIFO may still leave
  drain()
  local function lamp_frames(ms)
    local n, t = 0, 0
    while t < ms do
      bus.send_message("CAN1", "Powertrain", { VehicleSpeed = 150 })
      local f = bus.recv("CAN1", 20)
      if f and f.id == 0x110 then n = n + 1 end
      t = t + 20
    end
    return n
  end
  check.equal(lamp_frames(400), 0, "LampFrame kept transmitting with tx disabled")
  d:session(0x01) -- leaving the non-default session re-enables communication
  drain()
  check.truthy(lamp_frames(400) > 0, "LampFrame did not resume after returning to default")
end)

test("UDS: functional TesterPresent is answered; a functional unsupported service is silent", function()
  local function functional(req_hex, wait_ms)
    local req = fromhex(req_hex)
    bus.send("CAN1", 0x7DF, string.char(#req) .. req .. string.rep("\0", 7 - #req))
    local t = 0
    while t < wait_ms do
      local f = bus.recv("CAN1", 20)
      if f and f.id == 0x102 then return f.data end
      t = t + 20
    end
    return nil
  end
  drain()
  local r = functional("3E 00", 300)
  check.truthy(r ~= nil, "no answer to a functional TesterPresent")
  check.equal(tohex(r:sub(1, 3)), "02 7E 00")
  check.equal(functional("19 02 FF", 300), nil, "a functional request answered 0x11")
end)

test("UDS: ECUReset answers first, then the diagnostic state is back at power-on", function()
  local d = diag()
  d:session(0x03)
  check.equal(tohex(d:raw(fromhex("11 01"))), "51 01")
  sleep_ms(100)
  -- back in default: 0x28 is refused as not-in-session again
  check.nrc(0x7F, function() d:raw(fromhex("28 00 01")) end)
end)

test("UDS: the application refuses the programming session (no bootloader handoff yet)", function()
  check.nrc(0x12, function() diag():session(0x02) end)
end)

test("UDS: S3 returns an idle extended session to default", function()
  local d = diag()
  d:session(0x03)
  check.equal(tohex(d:raw(fromhex("28 00 01"))), "68 00") -- allowed: extended
  sleep_ms(2600) -- s3_ms = 2000
  check.nrc(0x7F, function() d:raw(fromhex("28 00 01")) end)
  -- 2.6 s with no VehicleSpeed let the rx deadline expire and the lamp go out: leave no such
  -- frames buffered for the next script (secoc.lua reads the oldest SecureFrames it finds)
  drain()
end)

test("UDS: a suppressed functional ECUReset applies before the next request in the FIFO", function()
  local d = diag()
  d:session(0x03)
  drain()
  -- back to back, so both sit in the ECU's rx FIFO for one bridge pass: 11 81 (reset, no answer)
  -- functionally, then a physical 0x28 that is only allowed outside the default session
  bus.send("CAN1", 0x7DF, fromhex("02 11 81 00 00 00 00 00"))
  bus.send("CAN1", 0x101, fromhex("03 28 00 01 00 00 00 00"))
  local r, t = nil, 0
  while t < 300 and not r do
    local f = bus.recv("CAN1", 20)
    if f and f.id == 0x102 then r = f.data end
    t = t + 20
  end
  check.truthy(r ~= nil, "no answer to the physical request")
  check.equal(tohex(r:sub(1, 4)), "03 7F 28 7F", "served under the pre-reset session")
end)
