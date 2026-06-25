-- Integration test: drive the blobly `overspeed` example on vcan0 and assert the
-- WarnLamp (raw frame 0x101, byte0). Run headless by cantester_v.
local CH, LAMP = "CAN1", 0x110

-- drain all buffered frames, return the LATEST lamp byte seen (or nil)
local function latest_lamp()
  local last = nil
  while true do
    local f = bus.recv(CH, 0)        -- non-blocking
    if not f then break end
    if f.id == LAMP then last = string.byte(f.data, 1) end
  end
  return last
end

-- hold the stimulus and wait until the lamp reaches `want` (filter must converge)
local function expect_lamp(speed, rpm, want, timeout_ms)
  local left = timeout_ms
  while left > 0 do
    bus.send_message(CH, "Powertrain", { VehicleSpeed = speed, EngineSpeed = rpm })
    sleep_ms(10)
    if latest_lamp() == want then return true end
    left = left - 10
  end
  return false
end

test("speed > 120 km/h -> lamp ON (filter + cross-core)", function()
  check.truthy(expect_lamp(150, 0, 1, 1500), "lamp did not turn ON")
end)

test("speed 0 -> lamp OFF", function()
  check.truthy(expect_lamp(0, 0, 0, 1500), "lamp did not turn OFF")
end)

test("engine > 4000 rpm -> lamp ON (local HighRev)", function()
  check.truthy(expect_lamp(0, 5000, 1, 1500), "lamp did not turn ON via engine path")
end)

-- COM rx-deadline: when the bus goes silent past the 200ms timeout, the bridge
-- invalidates VehicleSpeed/EngineSpeed, so the lamp must drop OFF. We can still
-- observe it because LampFrame tx is "mixed" (cyclic heartbeat keeps sending it).
test("rx deadline: silent bus -> signals invalid -> lamp OFF (cyclic tx)", function()
  check.truthy(expect_lamp(150, 0, 1, 1500), "precondition: drove speed, lamp ON")
  sleep_ms(500)  -- stop driving Powertrain entirely (> timeout + propagation)
  check.equal(latest_lamp(), 0, "lamp OFF after rx deadline")
end)
