-- Translating (signal) gateway: `Speed` decoded from SrcFrame (0x100, at bit 0) on
-- can0 (CAN1=vcan0) must reappear RE-ENCODED into DstFrame (0x200, at bit 8) on can1
-- (CAN2=vcan1). The signal sits at a different bit position in each frame, so a raw
-- byte-forward would leave it at bit 0 — only a real decode + re-encode is correct.
-- @verifies REQ-TOPO-006, REQ-TOPO-008
test("signal route: Speed 0x100@bit0 -> 0x200@bit8 (decode + re-encode)", function()
  local src  = fromhex("34 12 00 00 00 00 00 00")  -- Speed = 0x1234 at bit 0 of SrcFrame
  local want = fromhex("00 34 12 00 00 00 00 00")  -- re-encoded at bit 8 of DstFrame
  local got = nil
  for _ = 1, 80 do
    bus.send("CAN1", 0x100, src)     -- inject SrcFrame on can0
    local f = bus.recv("CAN2", 20)   -- watch can1
    if f and f.id == 0x200 then got = f.data; break end
  end
  check.truthy(got ~= nil, "0x200 (DstFrame) appeared on can1")
  check.equal(got, want)             -- Speed moved bit 0 -> bit 8 (decode + re-encode)
end)
