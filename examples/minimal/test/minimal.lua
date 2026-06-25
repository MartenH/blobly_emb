-- Integration test: drive the `minimal` example (SpeedMonitor) on vcan0.
local CH, LAMP = "CAN1", 0x101

local function latest_lamp()
  local last = nil
  while true do
    local f = bus.recv(CH, 0)
    if not f then break end
    if f.id == LAMP then last = string.byte(f.data, 1) end
  end
  return last
end

local function expect_lamp(speed, want, timeout_ms)
  local left = timeout_ms
  while left > 0 do
    bus.send_message(CH, "Powertrain", { VehicleSpeed = speed })
    sleep_ms(10)
    if latest_lamp() == want then return true end
    left = left - 10
  end
  return false
end

test("speed > 120 km/h -> lamp ON", function()
  check.truthy(expect_lamp(150, 1, 1000), "lamp did not turn ON")
end)
test("speed 0 -> lamp OFF", function()
  check.truthy(expect_lamp(0, 0, 1000), "lamp did not turn OFF")
end)
