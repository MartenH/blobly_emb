-- UDS (ISO 14229) over ISO-TP on vcan0: drive the diag connection (Request 0x101
-- -> Response 0x102) with blobly_net's UDS client. Exercises the service dispatch
-- AND multi-frame segmentation (the 19-byte and 20-byte DIDs span several frames).
-- @verifies REQ-DIAG-002
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
