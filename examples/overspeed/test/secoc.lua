-- SecOC: the bridge authenticates SecureFrame (0x130) — byte0 Status, byte1
-- freshness, bytes2-5 a truncated AES-CMAC. The MAC's correctness is proven
-- @verifies SYS-REQ-SEC-001
-- against FIPS-197 / RFC 4493 vectors in comm/secoc's unit tests; here we confirm
-- on the wire that authenticated frames flow with an advancing freshness counter
-- and a freshness-dependent MAC (not a constant), and that Status tracks the lamp.
test("SecOC: SecureFrame has advancing freshness + a real (freshness-dependent) MAC", function()
  for _ = 1, 20 do bus.send_message("CAN1", "Powertrain", { VehicleSpeed = 150 }); sleep_ms(10) end
  local frames, tries = {}, 120
  while #frames < 5 and tries > 0 do
    local f = bus.recv("CAN1", 50)
    if f and f.id == 0x130 then frames[#frames + 1] = f.data end
    tries = tries - 1
  end
  check.truthy(#frames >= 3, "received SecureFrames, got " .. #frames)

  -- freshness (byte1) advances frame-to-frame
  for i = 2, #frames do
    check.truthy(string.byte(frames[i], 2) ~= string.byte(frames[i - 1], 2), "freshness advanced")
  end
  -- the 4-byte MAC (bytes 2..5) is non-zero and differs across frames (it's keyed
  -- over the freshness, so a constant/forged tag wouldn't track it)
  local function mac(d) return string.sub(d, 3, 6) end
  check.truthy(mac(frames[1]) ~= "\0\0\0\0", "MAC is non-zero")
  check.truthy(mac(frames[1]) ~= mac(frames[2]), "MAC depends on freshness")
  -- Status (byte0) reflects the lamp (we drove > 120 km/h)
  check.equal(string.byte(frames[#frames], 1), 1)
end)
