-- Two-channel ECU: send VehicleSpeed on can0 (CAN1), assert WarnLamp appears on
-- can1 (CAN2). Proves a signal flows in one bus, through the FB, out the other.
local IN, OUT, LAMP = "CAN1", "CAN2", 0x110

local function latest_lamp()
  local last = nil
  while true do
    local f = bus.recv(OUT, 0)
    if not f then break end
    if f.id == LAMP then last = string.byte(f.data, 1) end
  end
  return last
end

local function expect_lamp(speed, want, timeout_ms)
  local left = timeout_ms
  while left > 0 do
    bus.send_message(IN, "Powertrain", { VehicleSpeed = speed })
    sleep_ms(10)
    if latest_lamp() == want then return true end
    left = left - 10
  end
  return false
end

test("VehicleSpeed in on can0 -> lamp ON out on can1", function()
  check.truthy(expect_lamp(150, 1, 1500), "lamp did not turn ON on can1")
end)

test("speed 0 -> lamp OFF on can1", function()
  check.truthy(expect_lamp(0, 0, 1500), "lamp did not turn OFF on can1")
end)
