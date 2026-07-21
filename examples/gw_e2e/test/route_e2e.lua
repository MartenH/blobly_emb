-- The dest producer RE-PROTECTS a routed frame: Speed decoded from SrcFrame (0x100,
-- unprotected) on can0 is re-encoded into DstFrame (0x200) on can1, and the producer
-- stamps a FRESH E2E counter + CRC each cycle (data_id 0x2A, CRC byte6, counter byte7).
-- Independently recompute the CRC (SAE J1850 CRC-8, the AUTOSAR-E2E poly) and check the
-- counter advances — i.e. a downstream E2E receiver would accept the re-framed value.
-- CAN1 = vcan0 (inject SrcFrame), CAN2 = vcan1 (read DstFrame).
-- @verifies REQ-TOPO-008

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

-- CRC over data_id (lo,hi) + every frame byte except crc_pos
local function expected_crc(data, data_id, dlc, crc_pos)
  local b = { data_id & 0xFF, (data_id >> 8) & 0xFF }
  for i = 0, dlc - 1 do
    if i ~= crc_pos then b[#b + 1] = string.byte(data, i + 1) end
  end
  return crc8(b)
end

test("routed DstFrame carries the re-encoded value + a valid, fresh E2E trailer", function()
  -- Speed 10.0 km/h: SrcFrame raw 100 (x0.1) at bit0; DstFrame raw 10 (x1) at bit8 (bytes 1-2)
  local src = fromhex("64 00 00 00 00 00 00 00")
  local frames, tries = {}, 200
  while #frames < 4 and tries > 0 do
    bus.send("CAN1", 0x100, src)
    local f = bus.recv("CAN2", 20)
    if f and f.id == 0x200 then frames[#frames + 1] = f.data end
    tries = tries - 1
  end
  check.truthy(#frames >= 3, "received re-protected DstFrames, got " .. #frames)
  -- the routed value survived: Speed raw 10 at bit8 = byte1=0x0A, byte2=0x00
  check.equal(string.byte(frames[1], 2), 0x0A)
  check.equal(string.byte(frames[1], 3), 0x00)
  -- every frame's CRC (byte7, crc_pos=6 -> index 7) matches an independent recompute
  for _, d in ipairs(frames) do
    check.equal(string.byte(d, 7), expected_crc(d, 0x2A, 8, 6))
  end
  -- the alive counter (low nibble of byte8, counter_pos=7) advances frame-to-frame
  for i = 2, #frames do
    local prev = string.byte(frames[i - 1], 8) & 0x0F
    local cur = string.byte(frames[i], 8) & 0x0F
    check.truthy(cur ~= prev, "E2E counter advanced (" .. prev .. " -> " .. cur .. ")")
  end
end)

test("routed DstFrame2 is SecOC-authenticated (advancing freshness + real MAC)", function()
  -- Rpm 3000 (0x0BB8) at bit0 of SrcFrame2; re-encoded at bit48 (bytes 6-7) of DstFrame2
  local src = fromhex("B8 0B 00 00 00 00 00 00")
  local frames, tries = {}, 200
  while #frames < 4 and tries > 0 do
    bus.send("CAN1", 0x101, src)
    local f = bus.recv("CAN2", 20)
    if f and f.id == 0x201 then frames[#frames + 1] = f.data end
    tries = tries - 1
  end
  check.truthy(#frames >= 3, "received SecOC-authenticated DstFrame2s, got " .. #frames)
  -- routed value survived: Rpm raw 3000 at bit48 = byte7=0xB8, byte8=0x0B
  check.equal(string.byte(frames[1], 7), 0xB8)
  check.equal(string.byte(frames[1], 8), 0x0B)
  -- freshness (byte2, fresh_pos=1) advances frame-to-frame
  for i = 2, #frames do
    check.truthy(string.byte(frames[i], 2) ~= string.byte(frames[i - 1], 2), "freshness advanced")
  end
  -- the 4-byte MAC (bytes 3..6, mac_pos=2) is non-zero and freshness-dependent (varies).
  -- MAC correctness itself is proven against RFC 4493 vectors in comm/secoc's unit tests.
  local function mac(d) return string.sub(d, 3, 6) end -- mac_pos=2 -> frame bytes 2..5 -> 1-based 3..6
  check.truthy(mac(frames[1]) ~= "\0\0\0\0", "MAC is non-zero")
  check.truthy(mac(frames[1]) ~= mac(frames[2]), "MAC depends on freshness")
end)
