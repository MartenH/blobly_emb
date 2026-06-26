-- Raw-PDU gateway: a frame the ECU doesn't decode (WheelSpeeds, 0x300) sent on
-- can0 (CAN1=vcan0) must reappear, byte-for-byte, on can1 (CAN2=vcan1).
test("raw-PDU gateway: WheelSpeeds forwarded can0 -> can1 untouched", function()
  local payload = fromhex("DE AD BE EF 11 22 33 44")
  local got = nil
  for _ = 1, 80 do
    bus.send("CAN1", 0x300, payload)   -- inject on can0
    local f = bus.recv("CAN2", 20)     -- watch can1
    if f and f.id == 0x300 then got = f.data; break end
  end
  check.truthy(got ~= nil, "0x300 was forwarded to can1")
  check.equal(got, payload)            -- bytes unchanged (raw forward, no decode)
end)
