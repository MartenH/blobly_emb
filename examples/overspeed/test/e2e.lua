-- E2E: the bridge stamps an alive counter + CRC into LampFrame (0x110, 3 bytes:
-- byte0 WarnLamp, byte1 CRC, byte2 counter). Independently recompute the CRC here
-- (SAE J1850 CRC-8, the AUTOSAR-E2E poly) and check the counter advances.
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

-- CRC over data_id (lo,hi) + frame bytes except crc_pos
local function expected_crc(data, data_id, dlc, crc_pos)
  local b = { data_id & 0xFF, (data_id >> 8) & 0xFF }
  for i = 0, dlc - 1 do
    if i ~= crc_pos then b[#b + 1] = string.byte(data, i + 1) end
  end
  return crc8(b)
end

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
    check.equal(string.byte(d, 2), expected_crc(d, 0x10, 3, 1))
  end
  -- the alive counter (low nibble of byte2) advances frame-to-frame
  for i = 2, #frames do
    local prev = string.byte(frames[i - 1], 3) & 0x0F
    local cur = string.byte(frames[i], 3) & 0x0F
    check.truthy(cur ~= prev, "alive counter advanced (" .. prev .. " -> " .. cur .. ")")
  end
end)
