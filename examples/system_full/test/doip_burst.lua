-- @project doip_bench.blobnet
-- sysnode's DoIP server under a burst of DIFFERENT requests on one TCP connection: each answer
-- must be the answer to its own request (MartenH/blobly_net#373 on real TCP). Carried over from
-- the retired examples/h735_doip bench (#340). Bench only (the H735 running sysnode on the LAN):
--   BLOBLY_NET=/path/to/blobly_net; cd $BLOBLY_NET && v -enable-globals \
--     -path "@vlib|@vmodules|modules" run cmd/script/run.v <blobly_emb>/examples/system_full/test/doip_burst.lua
local vin = "BLOBLYSYSNODEH735" -- DID 0xF190, as doip_sysnode.lua reads it

test("a burst of DIFFERENT requests stays correlated", function()
  -- alternating requests whose answers differ: an answer one behind would be caught
  local d = uds.open("sysnode")
  for i = 1, 25 do
    local s = (i % 2 == 0) and 0x03 or 0x01
    check.equal(tohex(d:raw(string.char(0x10, s))):sub(1, 5), string.format("50 %02X", s), "session " .. i)
    check.equal(d:read_did(0xF190), vin, "read " .. i)
  end
  d:session(0x01)
end)
