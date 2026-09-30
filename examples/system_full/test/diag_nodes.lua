-- @project ../system_full.blobnet
-- UDS on the target beyond the domain node (docs/diagnostics.md): the gateway (sysnode, H735) on
-- the compute bus, and zone_a (H723) on the EDGE bus — CAN-FD, carrying classic-sized ISO-TP — each
-- serving ISO 14229 from its ThreadX comm thread while it keeps routing and transmitting. The same
-- checks run on both; diag_domain.lua is the full set, this proves the server and the board seam
-- (TRNG seed, reset, keep cell) on two more chips. Bench only (the flashed boards on the CANsub).
--   BLOBLY_NET=/path/to/blobly_net; v -enable-globals -path "@vlib|@vmodules|$BLOBLY_NET/modules" \
--     run $BLOBLY_NET/cmd/script/run.v examples/system_full/test/diag_nodes.lua
-- After flashing with `st-flash --connect-under-reset`, the core-reset vector catch (DEMCR
-- VC_CORERESET) can stay armed: 0x11 then parks the core at reset_handler, "halted due to
-- breakpoint", and the node never comes back — a probe artifact, not the firmware. Clear it first:
--   openocd -f interface/stlink.cfg -c "adapter serial <sn>" -f target/stm32h7x.cfg \
--     -c "init; reset halt; mww 0xE000EDFC 0x01000000; resume; shutdown"

local nodes = {
  { name = "sysnode", bus = "compute", req = 0x7A0, rsp = 0x7A8, ident = "BLOBLY-SYSNODE-H735" },
  { name = "zone_a", bus = "edge", req = 0x7C0, rsp = 0x7C8, ident = "BLOBLY-ZONE_A-H723" },
}

local function diag(n) return uds.open(n.bus, { tx = n.req, rx = n.rsp }) end
local wrong = function(seed) return seed end

for _, n in ipairs(nodes) do
  test(n.name .. ": tester present, the extended session, and constant DIDs multi-frame", function()
    local d = diag(n)
    d:tester_present()
    check.truthy(#d:session(0x03) >= 4, "session answered with its P2/P2* timing")
    d:session(0x01)
    check.equal(d:read_did(0xF190), n.ident)
    check.equal(d:read_did(0xF189), "system_full")
  end)

  test(n.name .. ": what the target does not serve is refused, not faked", function()
    local d = diag(n)
    check.nrc(0x12, function() d:session(0x02) end)
    check.nrc(0x31, function() d:read_did(0xABCD) end)
  end)

  -- 0x27 through the board seam (boards/common/diag_board.c): this chip's TRNG, the reference key
  test(n.name .. ": 0x27 unlocks a gated DID; seeds differ; relocked by the session", function()
    local d = diag(n)
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

  -- security_attempts = 3, security_delay_ms = 3000; the lockout is kept across the node's own
  -- restart (the keep cell in D3 SRAM4), and 0x11 is answered before the reset
  test(n.name .. ": wrong keys lock 0x27 out, and the lockout runs on through ECUReset", function()
    local d = diag(n)
    d:session(0x03)
    check.nrc(0x35, function() d:security_access(0x01, wrong) end)
    check.nrc(0x35, function() d:security_access(0x01, wrong) end)
    check.nrc(0x36, function() d:security_access(0x01, wrong) end)
    check.equal(tohex(d:raw("\x11\x01")), "51 01")
    sleep_ms(2000)
    check.nrc(0x31, function() d:write_did(0x0102, "\x01") end) -- default session after the restart
    d:session(0x03)
    check.nrc(0x37, function() d:raw("\x27\x01") end)
    sleep_ms(3200)
    d:tester_present()
    d:security_access(0x01)
    d:session(0x01)
  end)
end

-- zone_a's live DID answers what it transmits: SteeringAngle, u32 LE in SteeringFrame (0x132, an
-- FD frame on edge every 50 ms), u32 big-endian in the DID. The FB moves it at most a few degrees
-- a frame, so the DID lies within the frames around it give or take one frame's step.
test("zone_a: the live DID answers the SteeringAngle it transmits", function()
  local d = diag(nodes[2])
  local function wire()
    local f = expect("edge", 0x132, 500)
    local b = { string.byte(f.data, 1, 4) }
    return b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216
  end
  while bus.recv("edge", 0) do end
  local prev = wire()
  local before = wire()
  local v = d:read_did(0xF1A0)
  local after = wire()
  check.equal(#v, 4)
  local b = { string.byte(v, 1, 4) }
  local now = ((b[1] * 256 + b[2]) * 256 + b[3]) * 256 + b[4]
  local step = math.max(math.abs(before - prev), math.abs(after - before))
  log(string.format("SteeringAngle: wire %d, DID %d, wire %d (step %d)", before, now, after, step))
  check.between(now, math.min(before, after) - step, math.max(before, after) + step,
    "the DID follows the transmitted value")
end)
