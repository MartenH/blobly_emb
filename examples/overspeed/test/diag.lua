-- ISO-TP transport (ISO 15765-2): drive the diag connection (Request 0x101 ->
-- Response 0x102) on vcan0. Diag is a positive-response echo for now, so a raw
-- UDS request returns as [sid+0x40, ...rest]. A long request/response exercises
-- multi-frame segmentation (FF/CF/FC) in both directions. (cantester passes/returns
-- UDS payloads as byte strings.)
local function diag()
  return uds.open("CAN1", { tx = 0x101, rx = 0x102 })
end

test("ISO-TP single frame: short request echoes positive", function()
  local resp = diag():raw(fromhex("22 F1 90"))
  check.equal(string.byte(resp, 1), 0x62) -- 0x22 + 0x40 (positive response SID)
  check.equal(string.byte(resp, 2), 0xF1)
  check.equal(string.byte(resp, 3), 0x90)
end)

test("ISO-TP multi-frame: long request reassembled + response segmented", function()
  local req = string.char(0x2E, 0xF1, 0x90)
  for i = 1, 40 do req = req .. string.char(i) end -- 43 bytes -> FF + CFs
  local resp = diag():raw(req)
  check.equal(string.byte(resp, 1), 0x6E) -- 0x2E + 0x40
  check.equal(#resp, #req)
  for i = 2, #req do check.equal(string.byte(resp, i), string.byte(req, i)) end
end)
