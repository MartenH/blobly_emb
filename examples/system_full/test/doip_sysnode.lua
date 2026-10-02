-- @project doip_bench.blobnet
-- sysnode's diagnostic server over DoIP (ISO 13400, [doip] in its ecu.toml): discovery, then UDS
-- over TCP, then the same server from the compute bus — one server, one session, one security
-- state, whichever transport a tester uses. Bench only (the H735 on the LAN, the CANsub on compute):
--   BLOBLY_NET=/path/to/blobly_net; v -enable-globals -path "@vlib|@vmodules|$BLOBLY_NET/modules" \
--     run $BLOBLY_NET/cmd/script/run.v examples/system_full/test/doip_sysnode.lua
local vin = "BLOBLYSYSNODEH735" -- DID 0xF190, which DoIP announces
local wrong = function(seed) return seed end
local function can() return uds.open("compute", { tx = 0x7A0, rx = 0x7A8 }) end

test("discovery answers with the entity's address and the VIN DID", function()
  local ann = doip.discover("sysnode")
  check.equal(ann.logical_address, 0x07A0)
  check.equal(ann.vin, vin)
end)

test("UDS over DoIP: sessions, constant DIDs, what is not served", function()
  local d = uds.open("sysnode")
  d:tester_present()
  check.truthy(#d:session(0x03) >= 4, "session answered with its P2/P2* timing")
  check.equal(d:read_did(0xF190), vin)
  check.equal(d:read_did(0xF189), "system_full")
  check.nrc(0x12, function() d:session(0x02) end)
  check.nrc(0x31, function() d:read_did(0xABCD) end)
  d:session(0x01)
end)

test("0x27 over DoIP: the TRNG seed, the reference key, the gated write", function()
  local d = uds.open("sysnode")
  d:session(0x03)
  check.nrc(0x33, function() d:write_did(0x0102, "\x11") end)
  local s1 = d:raw("\x27\x01"):sub(3)
  local s2 = d:raw("\x27\x01"):sub(3)
  check.equal(#s1, 4)
  check.truthy(s1 ~= s2, "two seeds differ: " .. tohex(s1) .. " / " .. tohex(s2))
  d:security_access(0x01)
  d:write_did(0x0102, "\x11")
  check.equal(tohex(d:read_did(0x0102)), "11")
  d:session(0x01)
  d:session(0x03)
  check.nrc(0x33, function() d:write_did(0x0102, "\x22") end)
  d:session(0x01)
end)

-- one server, one session — but an unlock is the transport's that earned it: a network tester
-- never writes under a bus tester's unlock, nor the reverse (REQ-NET-012)
test("one server: the session is shared, each transport's unlock its own", function()
  local d, c = uds.open("sysnode"), can()
  d:session(0x03)
  d:security_access(0x01)
  check.nrc(0x33, function() c:write_did(0x0102, "\x33") end) -- DoIP's session, not its unlock
  d:write_did(0x0102, "\x44")
  check.equal(tohex(c:read_did(0x0102)), "44")
  c:security_access(0x01)
  c:write_did(0x0102, "\x55")
  check.nrc(0x33, function() d:write_did(0x0102, "\x66") end) -- CAN's unlock does not open DoIP
  c:session(0x01)
  check.nrc(0x31, function() d:write_did(0x0102, "\x77") end) -- CAN ended the session for both
end)

test("wrong keys lock 0x27 out over DoIP; ECUReset answers, restarts, and the lockout runs on", function()
  local d = uds.open("sysnode")
  d:session(0x03)
  check.nrc(0x35, function() d:security_access(0x01, wrong) end)
  check.nrc(0x35, function() d:security_access(0x01, wrong) end)
  check.nrc(0x36, function() d:security_access(0x01, wrong) end)
  -- the answer arrives before the reset: the reset waits for the tester's TCP acknowledgement
  check.equal(tohex(d:raw("\x11\x01")), "51 01")
  -- CAN is up within a second of the restart, the Ethernet link only after auto-negotiation: the
  -- kept lockout (3 s from boot) is seen on CAN
  sleep_ms(1000)
  local c = can()
  c:session(0x03)
  check.nrc(0x37, function() c:raw("\x27\x01") end)
  sleep_ms(3200)
  c:security_access(0x01)
  c:session(0x01)
  -- and DoIP comes back: the same entity, a fresh connection
  local back
  for _ = 1, 20 do
    local ok, ann = pcall(doip.discover, "sysnode")
    if ok and ann then back = ann break end
    sleep_ms(500)
  end
  check.truthy(back ~= nil, "DoIP did not come back after the restart")
  check.equal(back.logical_address, 0x07A0)
  check.equal(uds.open("sysnode"):read_did(0xF190), vin)
end)
