-- SOURCE verify: SrcFrame (0x100) is E2E-protected; the route decodes Speed only when
-- the source's E2E check passes, then re-encodes it into DstFrame (0x200). A tampered
-- source (bad CRC) is rejected, so its value never reaches the wire. We construct the
-- E2E frames here (SAE J1850 CRC-8, the same poly the gateway verifies with).
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

-- an 8-byte SrcFrame carrying `speed_raw` (bit0, x0.1) with a valid E2E trailer
-- (data_id 0x33, CRC byte6, counter low-nibble byte7); `corrupt` flips the CRC.
local function mkframe(speed_raw, ctr, corrupt)
  local d = { speed_raw & 0xFF, (speed_raw >> 8) & 0xFF, 0, 0, 0, 0, 0, ctr & 0x0F }
  local b = { 0x33, 0x00 } -- CRC over data_id (lo, hi) + every byte except crc_pos (6)
  for i = 0, 7 do if i ~= 6 then b[#b + 1] = d[i + 1] end end
  d[7] = crc8(b)
  if corrupt then d[7] = d[7] ~ 0xFF end -- break the CRC -> the source E2E check fails
  return string.char(table.unpack(d))
end

test("valid E2E source is verified, then routed to DstFrame", function()
  local ctr, got = 0, nil
  for _ = 1, 120 do
    ctr = (ctr + 1) & 0x0F
    bus.send("CAN1", 0x100, mkframe(100, ctr, false)) -- Speed 10.0 km/h (src raw 100 x0.1)
    local f = bus.recv("CAN2", 20)
    if f and f.id == 0x200 then got = f.data; break end
  end
  check.truthy(got ~= nil, "DstFrame appeared for a valid E2E source")
  check.equal(string.byte(got, 2), 0x0A) -- Speed re-encoded: dst raw 10 (x1) at bit8
  check.equal(string.byte(got, 3), 0x00)
end)

test("tampered E2E source (bad CRC) is rejected — its value never reaches the wire", function()
  -- prime the route with a few valid frames so the destination is alive
  local ctr = 0
  for _ = 1, 10 do ctr = (ctr + 1) & 0x0F; bus.send("CAN1", 0x100, mkframe(100, ctr, false)); sleep_ms(2) end
  while bus.recv("CAN2", 0) do end
  -- flood TAMPERED frames carrying a DIFFERENT value (Speed 88.0 -> src raw 880) with a
  -- broken CRC; if source-verify works, raw 88 (0x58) must never appear on DstFrame.
  local leaked = false
  for _ = 1, 100 do
    ctr = (ctr + 1) & 0x0F
    bus.send("CAN1", 0x100, mkframe(880, ctr, true))
    local f = bus.recv("CAN2", 5)
    while f do
      if f.id == 0x200 and string.byte(f.data, 2) == 0x58 then leaked = true end
      f = bus.recv("CAN2", 0)
    end
    sleep_ms(2)
  end
  check.truthy(not leaked, "tampered source value (raw 88) must never be re-encoded onto DstFrame")
end)
