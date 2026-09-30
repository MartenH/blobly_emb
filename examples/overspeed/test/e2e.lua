-- E2E: the bridge stamps an alive counter + CRC into LampFrame (0x110, 3 bytes:
-- byte0 WarnLamp, byte1 CRC, byte2 counter). The CRC is recomputed by blobly_net's own AUTOSAR E2E
-- Profile 1 (e2e.p01_crc, pinned to an independent implementation) and the counter must advance.


test("E2E: LampFrame carries a valid CRC + advancing alive counter", function()
  for _ = 1, 20 do bus.send_message("CAN1", "Powertrain", { VehicleSpeed = 150 }); sleep_ms(10) end
  local frames, tries = {}, 80
  while #frames < 4 and tries > 0 do
    local f = bus.recv("CAN1", 50)
    if f and f.id == 0x110 then frames[#frames + 1] = f.data end
    tries = tries - 1
  end
  check.truthy(#frames >= 3, "received E2E lamp frames, got " .. #frames)
  -- every frame's CRC (byte1) matches an independent recompute
  for _, d in ipairs(frames) do
    check.equal(string.byte(d, 2), e2e.p01_crc(d, 0x10, 1, 2))
  end
  -- the alive counter (low nibble of byte2) advances frame-to-frame
  for i = 2, #frames do
    local prev = string.byte(frames[i - 1], 3) & 0x0F
    local cur = string.byte(frames[i], 3) & 0x0F
    check.truthy(cur ~= prev, "alive counter advanced (" .. prev .. " -> " .. cur .. ")")
  end
end)
