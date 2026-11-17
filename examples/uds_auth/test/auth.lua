-- 0x29 Authentication on vcan0: the uds_auth node unlocks security level 1 with ISO 14229-1's
-- challenge-response (0x29 05 / 06, Ed25519) instead of 0x27, through blobly_net's
-- diag:authenticate (the dev tester key by default — the one auth_keys "reference" trusts).
-- (Not tagged: REQ-DIAG-120..126 are verified by comm/uds, comm/udsauth, comm/diag and loom2v's
--  unit tests; tagging this pending suite with them would demote them. It is their on-bus evidence:
--  the generated host bridge wiring the keys, over ISO-TP — multi-frame both ways.)
local function diag()
  return uds.open("CAN1", { tx = 0x101, rx = 0x102 })
end

-- a key that is not the one the node trusts (64 hex, a valid seed of somebody else's)
local WRONG = string.rep("11", 32)

test("0x27 is not served on an authenticating node", function()
  local d = diag()
  d:session(0x03)
  check.nrc(0x11, function() d:raw(fromhex("27 01")) end)
end)

test("the gated DID needs the level; authenticate opens it", function()
  local d = diag()
  d:session(0x03)
  check.nrc(0x33, function() d:read_did(0xF1B0) end)
  d:authenticate(1)
  check.equal(d:read_did(0xF1B0), "SECRET-LEVEL-1")
end)

test("a session entry relocks; so does deAuthenticate", function()
  local d = diag()
  d:session(0x03)
  d:authenticate(1)
  d:session(0x03)
  check.nrc(0x33, function() d:read_did(0xF1B0) end)
  d:authenticate(1)
  check.equal(tohex(d:raw(fromhex("29 00"))), "69 00 10")
  check.nrc(0x33, function() d:read_did(0xF1B0) end)
end)

test("not in the default session; a proof with no challenge is a sequence error", function()
  local d = diag()
  d:session(0x01)
  check.nrc(0x7F, function() d:authenticate(1) end)
  d:session(0x03)
  check.nrc(0x24, function() d:raw(fromhex("29 06 06 03 2B 65 70" .. string.rep(" 00", 11) .. " 00 40"
    .. string.rep(" 00", 64) .. " 00 00 00 00")) end)
end)

test("failed proofs count like wrong keys: 0x58, 0x58, 0x36, then the lockout", function()
  local d = diag()
  d:session(0x03)
  check.nrc(0x58, function() d:authenticate(1, { key = WRONG }) end)
  check.nrc(0x58, function() d:authenticate(1, { key = WRONG }) end)
  check.nrc(0x36, function() d:authenticate(1, { key = WRONG }) end)
  check.nrc(0x37, function() d:authenticate(1) end)
  sleep_ms(1100) -- security_delay_ms = 1000
  d:authenticate(1)
  check.equal(d:read_did(0xF1B0), "SECRET-LEVEL-1")
end)

test("a functional 0x29 gets no answer", function()
  diag():session(0x03)
  while bus.recv("CAN1", 0) do end
  bus.send("CAN1", 0x7DF, fromhex("02 29 00 00 00 00 00 00"))
  local t = 0
  while t < 300 do
    local f = bus.recv("CAN1", 20)
    check.truthy(not (f and f.id == 0x102), "a functional 0x29 was answered")
    t = t + 20
  end
end)
