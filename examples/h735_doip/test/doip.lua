-- Bench suite for examples/h735_doip on the H735-DK (192.168.0.50:13400), driven by blobly_net's
-- headless runner over the LAN: discovery, routing activation and UDS over DoIP.
-- @project h735_doip.blobnet
test("discovery answers with the entity's identity", function()
  local ann = doip.discover("H735")
  check.truthy(ann, "no answer to identification")
  check.equal(ann.logical_address, 0x0E80)
  log("VIN " .. tostring(ann.vin))
end)

test("UDS over DoIP: sessions, a DID read, tester present", function()
  local d = uds.open("H735")
  d:session(0x03)
  local vin = d:read_did(0xF190)
  log("F190 = " .. vin)
  check.equal(vin, doip.discover("H735").vin, "the served VIN is not the announced one")
  d:tester_present()
  d:session(0x01)
end)

test("a burst of requests stays correlated (the #358 drain path on real TCP)", function()
  local d = uds.open("H735")
  for i = 1, 50 do
    local vin = d:read_did(0xF190)
    check.truthy(#vin > 0, "request " .. i)
  end
end)
