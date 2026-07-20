-- Translating (signal) gateway, P2a.2b: `Speed` is decoded from SrcFrame (0x100,
-- bit 0, factor 0.1) on can0 (CAN1=vcan0), and the destination frame's PRODUCER
-- re-emits it into DstFrame (0x200, bit 8, factor 1) on can1 (CAN2=vcan1) at the
-- destination's own 100 ms cadence. So the route TRANSCODES (0.1 -> 1) and
-- RATE-ADAPTS (20 ms source -> 100 ms destination), not just re-frames.
-- Send raw 100 @0.1 = 10.0 km/h; expect raw 10 @1 = 10.0 km/h at bit 8.
-- @verifies REQ-TOPO-006, REQ-TOPO-008
test("signal route: transcode 100@0.1 -> 10@1, re-emitted at the dest cadence", function()
  local src  = fromhex("64 00 00 00 00 00 00 00")  -- Speed raw 100 (=10.0 km/h) at bit 0
  local want = fromhex("00 0A 00 00 00 00 00 00")  -- raw 10 (=10.0 km/h) at bit 8 of DstFrame
  local got = nil
  for _ = 1, 120 do
    bus.send("CAN1", 0x100, src)     -- inject SrcFrame on can0 (faster than the dest)
    local f = bus.recv("CAN2", 20)   -- watch can1
    if f and f.id == 0x200 then got = f.data; break end
  end
  check.truthy(got ~= nil, "0x200 (DstFrame) appeared on can1")
  check.equal(got, want)             -- value 10.0 preserved across the factor change
end)
