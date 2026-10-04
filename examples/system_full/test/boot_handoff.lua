-- @project diag_bench.blobnet
-- The programming handoff and the field update on the target (docs/bootloader.md P3 and "The DoIP
-- binding", docs/diagnostics.md R2): each system_full node runs behind its bootloader ([boot]), and
-- its application's 0x10 02 hands the ECU over — answered 50 02, then the boot request cell and the
-- reset — to a boot manager that answers on the SAME ids and bus, already in the programming session
-- it was promised. A [doip] node's bootloader is its DoIP entity too: asked over DoIP, the tester's
-- TCP connection dies with the reset, it reconnects to the same address and logical address, and the
-- session is its own (REQ-BOOT-019). Bench only (the flashed boards on the CANsub and the LAN); needs
-- blobly_net's Lua `flash.program` (net #388).
--   BOOT_PHASE=flash     (default) per node: app → 0x10 03 (→ 0x27 where the node gates it) →
--                        0x10 02 → the boot answers on the app's ids (over DoIP: after the tester
--                        reconnects) → 0x29 challenge with no second 0x10 02 → flash.program over
--                        THAT connection (0x29, erase, transfer, check + mark, reset) → the new image
--                        runs and its version DID 0xF195 is BOOT_VERSION. The image is
--                        nodes/<node>/build/<node>.img, built first with
--                        `make -C nodes/<node> image SW_VERSION=$BOOT_VERSION` (boot_bench.sh does both)
--   BOOT_PHASE=roundtrip the handoff, then 0x11 from the boot back to the application (no flash)
-- BOOT_NODES (comma-separated, default every entry) picks the entries: a node over CAN by its name,
-- over DoIP as <name>-doip (sysnode-doip, tcu-doip).
--   BLOBLY_NET=/path/to/blobly_net; BOOT_VERSION=<n> v -enable-globals \
--     -path "@vlib|@vmodules|$BLOBLY_NET/modules" run $BLOBLY_NET/cmd/script/run.v \
--     examples/system_full/test/boot_handoff.lua

local all = {
  { name = "domain", bus = "compute", req = 0x7B0, rsp = 0x7B8, ident = "BLOBLY-DOMAIN-H755" },
  -- a [doip] node: its "0x10 02" row needs level 1 (REQ-NET-012), earned here over CAN
  { name = "sysnode", bus = "compute", req = 0x7A0, rsp = 0x7A8, ident = "BLOBLYSYSNODEH735", level = 1 },
  -- the CAN-FD edge bus, classic-sized ISO-TP: the boot opens it in FD as the application does
  { name = "zone_a", bus = "edge", req = 0x7C0, rsp = 0x7C8, ident = "BLOBLY-ZONE_A-H723" },
  -- sysnode's bootloader over DoIP (diag_bench.blobnet's sysnode_ip): the handoff needs this network
  -- tester's own level 1 (REQ-NET-012), and the session it opens is the network's
  { name = "sysnode-doip", node = "sysnode", doip = "sysnode_ip", ident = "BLOBLYSYSNODEH735", level = 1 },
  -- tcu: on no CAN bus, so DoIP is the only way to its bootloader (tcu_ip, 192.168.0.51)
  { name = "tcu-doip", node = "tcu", doip = "tcu_ip", ident = "BLOBLY-TCU-H723-1", level = 1 },
}

local phase = os.getenv("BOOT_PHASE") or "flash"
local want = os.getenv("BOOT_NODES")
local nodes = {}
for _, n in ipairs(all) do
  if not want or want == "" or ("," .. want .. ","):find("," .. n.name .. ",", 1, true) then
    nodes[#nodes + 1] = n
  end
end

-- a node's connection; over DoIP uds.open hands back the channel's one connection, probing it and
-- reconnecting into the same handle when it is dead — which is how a tester follows the ECU across
-- the resets of a handoff
local function diag(n)
  if n.doip then return uds.open(n.doip) end
  return uds.open(n.bus, { tx = n.req, rx = n.rsp })
end

-- the longest the bootloader may take to answer after the handoff: over CAN clocks and the bus, a
-- few ms; over DoIP the PHY's auto-negotiation, NetX and the announcements, a few s — and the
-- tester's probe of the dead connection on top
local function up_tries(n) return n.doip and 60 or 20 end

local function be32(s)
  local b = { string.byte(s, 1, 4) }
  return ((b[1] * 256 + b[2]) * 256 + b[3]) * 256 + b[4]
end

-- the bootloader comes up a few ms after the reset (clocks, CAN): ask its identification until it
-- answers — F180, which only the boot serves
local function boot_up(d, n)
  local t0 = os.time()
  for _ = 1, up_tries(n) do
    local ok, v = pcall(function()
      if n.doip then d = diag(n) end -- the same handle, reconnected
      return d:read_did(0xF180)
    end)
    if ok then
      log(string.format("%s: the bootloader answered ~%d s after the handoff", n.name, os.time() - t0))
      return v
    end
    sleep_ms(100)
  end
  error("the bootloader never answered F180 on the application's ids")
end

local function handoff(n)
  local d = diag(n)
  d:session(0x01)
  local ver = be32(d:read_did(0xF195))
  check.equal(d:read_did(0xF190), n.ident, "the application answers before the handoff")
  check.nrc(0x7E, function() d:session(0x02) end) -- never from default
  d:session(0x03)
  if n.level then
    check.nrc(0x33, function() d:session(0x02) end) -- its row needs the level
    d:security_access(n.level)
  end
  local params = d:session(0x02)
  check.truthy(#params >= 4, "50 02 carries its P2/P2*")
  local bl = boot_up(d, n)
  log(string.format("%s: app image v%d handed off; bootloader %s", n.name, ver, tohex(bl)))
  check.equal(be32(d:read_did(0xF195)), ver, "the boot reports the image it was handed off from")
  -- the session survives the handoff: 0x29 at once, no second 0x10 02
  local ch = d:raw("\x29\x01")
  check.equal(tohex(ch:sub(1, 2)), "69 01")
  check.equal(#ch, 34, "a 32-byte challenge")
  return d
end

-- the application again, after a reset: its identity first (it may take a moment to come up)
local function app_back(d, n)
  for _ = 1, up_tries(n) do
    local ok, v = pcall(function()
      if n.doip then d = diag(n) end
      return d:read_did(0xF190)
    end)
    if ok then
      check.equal(v, n.ident)
      return
    end
    sleep_ms(100)
  end
  error("the application never came back after the reset")
end

for _, n in ipairs(nodes) do
  if phase == "flash" then
    test(n.name .. ": 0x10 02 hands over, the bootloader flashes the new image, and it runs", function()
      local want_ver = tonumber(os.getenv("BOOT_VERSION") or "")
      check.truthy(want_ver ~= nil, "BOOT_VERSION names the version built into the image")
      local d = handoff(n)
      local node = n.node or n.name
      local r = flash.program(d, { image = "../nodes/" .. node .. "/build/" .. node .. ".img" })
      check.equal(r.auth, "authenticated", "the boot required the 0x29 proof")
      check.truthy(r.wrapped, "the signed container went as it is")
      app_back(d, n)
      check.equal(be32(d:read_did(0xF195)), want_ver, "the image-version DID is the flashed image's")
    end)
  elseif phase == "roundtrip" then
    test(n.name .. ": the handoff, and 0x11 from the boot back to the application", function()
      local d = handoff(n)
      d:reset(1)
      app_back(d, n)
    end)
  else
    error("BOOT_PHASE " .. phase .. ": flash | roundtrip")
  end
end
