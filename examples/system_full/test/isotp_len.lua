-- @project diag_bench.blobnet
-- The configured maximum message length and frame length on the target ([isotp] max_message and
-- tx_dl, REQ-CAN-TP-014/021/023/025/026..028; docs/can-tp.md): zone_a opts in at 4095 and at TX_DL 64,
-- every other node keeps the default 520 and 8. A message longer than 520 goes whole to and from zone_a; the same message to domain is
-- refused — an answer too long for its connection is responseTooLong (0x14), a request too long is
-- refused by its first frame's flow control (FC.OVFLW); and through sysnode, whose maximum is 520, a
-- routed answer longer than that comes back responseTooLong from the gateway in zone_a's name, while a
-- routed request longer than that is the DoIP entity's to refuse (generic NACK 0x02, the message
-- discarded and the connection kept — ISO 13400-2's generic header handler). Bench only (the
-- flashed boards on the CANsub and the LAN):
--   BLOBLY_NET=/path/to/blobly_net; v -enable-globals \
--     run $BLOBLY_NET/cmd/script/run.v examples/system_full/test/isotp_len.lua

local zone_a = { bus = "edge", req = 0x7C0, rsp = 0x7C8, ident = "BLOBLY-ZONE_A-H723", logical = 0x07C0 }
local domain = { bus = "compute", req = 0x7B0, rsp = 0x7B8 }

local function diag(n) return uds.open(n.bus, { tx = n.req, rx = n.rsp }) end

-- a 0x22 naming F190 `n` times: its answer is 1 + n * (2 + the DID's length) bytes
local function reads(n)
  local r = "\x22"
  for _ = 1, n do r = r .. "\xF1\x90" end
  return r
end

-- a request of `n` bytes: TesterPresent with padding, which a server refuses with 0x13 — but only
-- once it has taken the whole request in
local function padded(n) return "\x3E\x00" .. string.rep("\x00", n - 2) end

test("zone_a answers a message longer than 520 whole", function()
  local d = diag(zone_a)
  local a = d:raw(reads(27)) -- 1 + 27 * 20 = 541 bytes
  check.equal(#a, 541)
  check.equal(a:sub(1, 1), "\x62")
  check.equal(a:sub(#a - 17), zone_a.ident, "the last record whole")
end)

test("zone_a takes a request longer than 520 whole", function()
  local d = diag(zone_a)
  check.nrc(0x13, function() d:raw(padded(600)) end) -- reassembled, then judged
  check.nrc(0x13, function() d:raw(padded(4095)) end) -- the most a first frame states
end)

test("domain, at the default 520: the long answer is 0x14, the long request FC.OVFLW", function()
  local d = diag(domain)
  check.nrc(0x14, function() d:raw(reads(27)) end)
  local ok, err = pcall(function() d:raw(padded(600)) end)
  check.truthy(not ok, "a 600-byte request to a 520-byte connection")
  local e = tostring(err):lower()
  check.truthy(e:find("overflow", 1, true) or e:find("too long", 1, true), tostring(err))
  check.equal(#d:raw("\x3E\x00"), 2, "the connection still serves")
end)

test("routed through sysnode (520), a message longer than 520 is the gateway's to refuse", function()
  local g = uds.open("sysnode_ip")
  g:session(0x03)
  g:security_access(0x01) -- the gateway's own unlock: routing needs it (REQ-NET-020)
  g:retarget(zone_a.logical)
  check.equal(g:read_did(0xF190), zone_a.ident, "zone_a answers through the gateway")
  -- zone_a answers 541 bytes; the gateway refuses that on the bus and answers 0x14 in its name
  check.nrc(0x14, function() g:raw(reads(27)) end)
  check.equal(g:read_did(0xF190), zone_a.ident, "the route still serves")
  local ok, err = pcall(function() g:raw(padded(600)) end)
  check.truthy(not ok, "a 600-byte routed request through a 520-byte gateway")
  -- the generic NACK answers no request: the tester waits out its P2, not a lost connection
  check.truthy(not tostring(err):find("lost", 1, true), "the entity kept the connection: " .. tostring(err))
  -- ... with its routing activation, the gateway's unlock and the retarget: the route still serves
  check.equal(g:read_did(0xF190), zone_a.ident, "the route serves on the same connection")
end)

-- zone_a sends at TX_DL 64 ([isotp] tx_dl = 64): a single frame of up to 62 bytes behind the CAN-FD
-- escape, consecutive frames of 63; and it takes a tester's 64-byte frames with no setting of its own
test("zone_a exchanges 64-byte CAN-FD frames both ways", function()
  local d = uds.open(zone_a.bus, { tx = zone_a.req, rx = zone_a.rsp, tx_dl = 64 })
  check.equal(d:read_did(0xF190), zone_a.ident, "a 21-byte answer, behind the escape")
  check.equal(#d:raw(reads(27)), 541, "a 541-byte answer, in 63-byte consecutive frames")
  check.nrc(0x13, function() d:raw(padded(4095)) end) -- our 64-byte frames reassembled, then judged
  -- on the wire, through a raw ISO-TP channel: the frames are as long as the escape and TX_DL make them
  bus.recv(zone_a.bus, 0) -- this script's handle reads the edge bus from here
  local tp = isotp.open(zone_a.bus, { tx = zone_a.req, rx = zone_a.rsp, tx_dl = 64 })
  tp:send("\x22\xF1\x90")
  local sf = expect(zone_a.bus, zone_a.rsp, 1000)
  check.equal(#sf.data, 24, "21 bytes behind the escape: a 24-byte frame")
  check.equal(sf.data:byte(1), 0x00, "the escape")
  check.equal(sf.data:byte(2), 21, "its length in the second byte")
  check.equal(#tp:recv(1000), 21)
  tp:send(reads(27)) -- 55 bytes: one single frame behind the escape
  local ff = expect(zone_a.bus, zone_a.rsp, 1000)
  check.equal(#ff.data, 64, "its first frame: 64 bytes")
  check.equal(ff.data:byte(1), 0x12, "a first frame of 0x21D (541) bytes")
  check.equal(ff.data:byte(2), 0x1D)
  check.equal(#tp:recv(1000), 541)
  tp:close()
end)

-- routed through sysnode, whose route to zone_a carries its TX_DL 64 (sysgen lowers it): the gateway
-- sends zone_a its requests in 64-byte frames, and the answers come back whole
test("routed through sysnode, zone_a's route sends 64-byte frames", function()
  local g = uds.open("sysnode_ip")
  g:session(0x03)
  g:security_access(0x01)
  g:retarget(zone_a.logical)
  bus.recv(zone_a.bus, 0)
  check.nrc(0x13, function() g:raw(padded(500)) end) -- the gateway's 520 holds it: forwarded whole
  local ff = expect(zone_a.bus, zone_a.req, 1000)
  check.equal(#ff.data, 64, "the gateway's first frame to zone_a: 64 bytes")
  check.equal(g:read_did(0xF190), zone_a.ident, "the route still serves")
end)
