-- Bench suite for examples/h735_doip on the H735-DK (192.168.0.50:13400): discovery, routing
-- activation and UDS over DoIP, driven by blobly_net's headless runner from any LAN host:
--
--   cd <blobly_net> && v -enable-globals -path "@vlib|@vmodules|modules|libs" run cmd/script \
--     <blobly_emb>/examples/h735_doip/bench/doip.lua
--
-- A bench suite, not a `make test` one: it needs the board on the network.
-- @project h735_doip.blobnet
local vin = "BLOBLYH735DK00001" -- main.v's

test("discovery answers with the entity's identity", function()
  local ann = doip.discover("H735")
  check.equal(ann.logical_address, 0x0E80)
  check.equal(ann.vin, vin)
end)

test("UDS over DoIP: sessions, the VIN DID, tester present", function()
  local d = uds.open("H735")
  d:session(0x03)
  -- 0xF190 is the VIN the entity announces: two different ones could not be told apart
  check.equal(d:read_did(0xF190), vin)
  d:tester_present()
  d:session(0x01)
end)

test("a burst of DIFFERENT requests stays correlated (MartenH/blobly_net#373 on real TCP)", function()
  -- alternating requests whose answers differ: an answer one behind would be caught
  local d = uds.open("H735")
  for i = 1, 25 do
    local s = (i % 2 == 0) and 0x03 or 0x01
    check.equal(tohex(d:raw(string.char(0x10, s))):sub(1, 5), string.format("50 %02X", s), "session " .. i)
    check.equal(d:read_did(0xF190), vin, "read " .. i)
  end
  d:session(0x01)
end)
