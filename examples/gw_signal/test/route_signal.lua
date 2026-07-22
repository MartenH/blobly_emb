-- Translating (signal) gateway, P2a.2b — the value routes through the destination
-- frame's PRODUCER, so it TRANSCODES (factor 0.1 -> 1) and RATE-ADAPTS (a 20 ms
-- source re-emitted at the destination's 100 ms cadence). CAN1=vcan0, CAN2=vcan1.
-- A second route re-encodes Rpm into an EXTENDED (29-bit) destination frame.
-- @verifies REQ-TOPO-006, REQ-TOPO-008

test("signal route: transcode 100@0.1 -> 10@1 (value preserved across the factor)", function()
  local src  = fromhex("64 00 00 00 00 00 00 00")  -- Speed raw 100 (=10.0 km/h) at bit 0, x0.1
  local want = fromhex("00 0A 00 00 00 00 00 00")  -- raw 10 (=10.0 km/h) at bit 8 of DstFrame, x1
  local got = nil
  for _ = 1, 120 do
    bus.send("CAN1", 0x100, src)
    local f = bus.recv("CAN2", 20)
    if f and f.id == 0x200 then got = f.data; break end
  end
  check.truthy(got ~= nil, "0x200 (DstFrame) appeared on can1")
  check.equal(got, want)
end)

test("signal route: rate-adapts (dest emits at its 100 ms cadence, not on receipt)", function()
  -- drive the source FAST (~every 10 ms) for ~600 ms; a rate-adapting producer emits
  -- the dest at 100 ms (~6 frames), an on-receipt forwarder would emit ~60.
  local src = fromhex("64 00 00 00 00 00 00 00")
  -- drain any backlog first
  while bus.recv("CAN2", 0) do end
  local count = 0
  for _ = 1, 60 do
    bus.send("CAN1", 0x100, src)
    local f = bus.recv("CAN2", 0)
    while f do
      if f.id == 0x200 then count = count + 1 end
      f = bus.recv("CAN2", 0)
    end
    sleep_ms(10)
  end
  check.truthy(count >= 4 and count <= 10,
    "dest re-emits at ~100 ms cadence (~6 frames in ~600 ms), not on receipt (got " .. count .. ")")
end)

test("signal route into an EXTENDED (29-bit) destination frame (ExtDst 0x18FF0200)", function()
  local src  = fromhex("00 00 D0 07 00 00 00 00")  -- Rpm raw 2000 (0x07D0) at bit 16 of SrcFrame
  local want = fromhex("D0 07 00 00 00 00 00 00")  -- Rpm 2000 at bit 0 of ExtDst
  local got = nil
  for _ = 1, 120 do
    bus.send("CAN1", 0x100, src)
    local f = bus.recv("CAN2", 20)
    if f and f.id == 0x18FF0200 and f.ext then got = f.data; break end
  end
  check.truthy(got ~= nil, "ExtDst (0x18FF0200, extended id) appeared on can1")
  check.equal(got, want)
end)
