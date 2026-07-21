-- The DISSOLUTION gateway, end-to-end on two vcans. system.toml declares the route
-- ONCE (VehicleSpeed, compute:VehSpeedFrame -> edge:VehSpeed_E); sysgen lowers it into
-- this node's gen file, dbcmerge fuses the per-bus DBCs, and loom2v generates the
-- destination-producer forwarder. Here nothing is hand-wired — we only inject the
-- source frame and watch the edge bus. CAN1 = vcan0 (compute), CAN2 = vcan1 (edge).
-- @verifies REQ-TOPO-006, REQ-TOPO-008

test("dissolution route: VehSpeedFrame(0x120) on compute -> VehSpeed_E(0x200) on edge", function()
  local src  = fromhex("E8 03 00 00 00 00 00 00")  -- VehicleSpeed = 1000 (0x3E8), 32b @ bit0, x1
  local want = fromhex("E8 03 00 00 00 00 00 00")  -- same physical value re-framed on edge (x1)
  local got = nil
  for _ = 1, 120 do
    bus.send("CAN1", 0x120, src)
    local f = bus.recv("CAN2", 20)
    if f and f.id == 0x200 then got = f.data; break end
  end
  check.truthy(got ~= nil, "0x200 (VehSpeed_E) appeared on the edge bus")
  check.equal(got, want)
end)

test("dissolution route: rate-adapts to the edge cadence (200 ms, not on receipt)", function()
  -- drive the source fast (~10 ms) for ~600 ms; a rate-adapting producer emits the dest
  -- at its 200 ms cadence (~3 frames), an on-receipt forwarder would emit ~60.
  local src = fromhex("E8 03 00 00 00 00 00 00")
  while bus.recv("CAN2", 0) do end -- drain backlog
  local count = 0
  for _ = 1, 60 do
    bus.send("CAN1", 0x120, src)
    local f = bus.recv("CAN2", 0)
    while f do
      if f.id == 0x200 then count = count + 1 end
      f = bus.recv("CAN2", 0)
    end
    sleep_ms(10)
  end
  check.truthy(count >= 2 and count <= 8,
    "edge re-emits at ~200 ms cadence (~3 frames in ~600 ms), not on receipt (got " .. count .. ")")
end)
