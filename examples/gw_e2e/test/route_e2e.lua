-- The dest producer RE-PROTECTS a routed frame: Speed decoded from SrcFrame (0x100,
-- unprotected) on can0 is re-encoded into DstFrame (0x200) on can1, and the producer
-- stamps a FRESH E2E counter + CRC each cycle (data_id 0x2A, CRC byte6, counter byte7).
-- A second route re-encodes Rpm into a SecOC-authenticated DstFrame2 (0x201). Both are
-- verified CRYPTOGRAPHICALLY: the E2E CRC is recomputed (SAE J1850) and the SecOC MAC
-- is recomputed (AES-128-CMAC, RFC 4493) — i.e. a downstream receiver would accept them.
-- CAN1 = vcan0 (inject source), CAN2 = vcan1 (read protected dest).
-- @verifies REQ-TOPO-008

-- ---- E2E: SAE J1850 CRC-8 (the AUTOSAR-E2E poly) ----
local function crc8(bytes)
  local crc = 0xFF
  for _, b in ipairs(bytes) do
    crc = crc ~ b
    for _ = 1, 8 do
      if crc & 0x80 ~= 0 then crc = ((crc << 1) ~ 0x1D) & 0xFF else crc = (crc << 1) & 0xFF end
    end
  end
  return crc ~ 0xFF
end
local function expected_crc(data, data_id, dlc, crc_pos) -- over data_id (lo,hi) + bytes except crc_pos
  local b = { data_id & 0xFF, (data_id >> 8) & 0xFF }
  for i = 0, dlc - 1 do
    if i ~= crc_pos then b[#b + 1] = string.byte(data, i + 1) end
  end
  return crc8(b)
end

-- ---- SecOC: AES-128 + CMAC (RFC 4493), pure Lua, to independently verify the MAC ----
local SBOX = (function()
  local h = "637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0" ..
            "b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275" ..
            "09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cf" ..
            "d0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2" ..
            "cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdb" ..
            "e0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08" ..
            "ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9e" ..
            "e1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16"
  local t = {}
  for i = 0, 255 do t[i] = tonumber(h:sub(i * 2 + 1, i * 2 + 2), 16) end
  return t
end)()
local RCON = { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36 }
local function xtime(a) local r = a << 1; if a & 0x80 ~= 0 then r = r ~ 0x11b end; return r & 0xFF end
local function key_expand(key) -- key: 16 bytes (1-based) -> 176-byte round-key schedule (1-based)
  local rk = {}
  for i = 1, 16 do rk[i] = key[i] end
  local n, w = 16, 4 -- n = bytes generated; w = word index. AES-128 expands one WORD (4 bytes) at a time.
  while n < 176 do
    local t0, t1, t2, t3 = rk[n - 3], rk[n - 2], rk[n - 1], rk[n] -- temp = previous word
    if w % 4 == 0 then                                            -- every 4th word: rotword+subword+rcon
      t0, t1, t2, t3 = SBOX[rk[n - 2]], SBOX[rk[n - 1]], SBOX[rk[n]], SBOX[rk[n - 3]]
      t0 = t0 ~ RCON[w // 4]
    end
    rk[n + 1] = rk[n - 15] ~ t0 -- w[i] = w[i-4] ^ temp
    rk[n + 2] = rk[n - 14] ~ t1
    rk[n + 3] = rk[n - 13] ~ t2
    rk[n + 4] = rk[n - 12] ~ t3
    n, w = n + 4, w + 1
  end
  return rk
end
local function aes_encrypt(rk, blk) -- blk: 16 bytes (1-based) -> 16-byte cipher (1-based)
  local s = {}
  for i = 1, 16 do s[i] = blk[i] ~ rk[i] end
  for round = 1, 10 do
    for i = 1, 16 do s[i] = SBOX[s[i]] end                                  -- SubBytes
    local r = { s[1], s[6], s[11], s[16], s[5], s[10], s[15], s[4],         -- ShiftRows (column-major)
                s[9], s[14], s[3], s[8], s[13], s[2], s[7], s[12] }
    s = r
    if round < 10 then                                                      -- MixColumns
      for c = 0, 3 do
        local a0, a1, a2, a3 = s[c * 4 + 1], s[c * 4 + 2], s[c * 4 + 3], s[c * 4 + 4]
        s[c * 4 + 1] = xtime(a0) ~ (xtime(a1) ~ a1) ~ a2 ~ a3
        s[c * 4 + 2] = a0 ~ xtime(a1) ~ (xtime(a2) ~ a2) ~ a3
        s[c * 4 + 3] = a0 ~ a1 ~ xtime(a2) ~ (xtime(a3) ~ a3)
        s[c * 4 + 4] = (xtime(a0) ~ a0) ~ a1 ~ a2 ~ xtime(a3)
      end
    end
    for i = 1, 16 do s[i] = s[i] ~ rk[round * 16 + i] end                   -- AddRoundKey
  end
  return s
end
local function dbl(b) -- GF(2^128) x2 for CMAC subkeys
  local out, carry = {}, 0
  for i = 16, 1, -1 do local v = (b[i] << 1) | carry; out[i] = v & 0xFF; carry = (v >> 8) & 1 end
  if carry == 1 then out[16] = out[16] ~ 0x87 end
  return out
end
local function cmac(key, msg) -- key: 16 bytes, msg: table of bytes (0..n) -> 16-byte tag (1-based)
  local rk = key_expand(key)
  local z = {}; for i = 1, 16 do z[i] = 0 end
  local k1 = dbl(aes_encrypt(rk, z))
  local k2 = dbl(k1)
  local n = #msg
  local nblocks = math.max(1, math.ceil(n / 16))
  local x = {}; for i = 1, 16 do x[i] = 0 end
  for blk = 0, nblocks - 1 do
    local m = {}
    local last = (blk == nblocks - 1)
    local complete = (n % 16 == 0) and (n > 0)
    for i = 1, 16 do
      local idx = blk * 16 + i
      local b = (idx <= n) and msg[idx] or (idx == n + 1 and 0x80 or 0x00)
      if last and not complete then
        b = b ~ k2[i]
      elseif last and complete then
        b = b ~ k1[i]
      end
      m[i] = b ~ x[i]
    end
    x = aes_encrypt(rk, m)
  end
  return x
end

-- self-check against the RFC 4493 vector (empty message) so a broken AES fails loudly here
local function rfc4493_key()
  local k = {}
  for i, b in ipairs({ 0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
                       0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c }) do k[i] = b end
  return k
end
local function tohex(t) local s = ""; for i = 1, #t do s = s .. string.format("%02x", t[i]) end; return s end

test("SELF-CHECK: Lua AES-128-CMAC matches the RFC 4493 empty-message vector", function()
  check.equal(tohex(cmac(rfc4493_key(), {})), "bb1d6929e95937287fa37d129b756746")
end)

-- ---- the routing tests ----

test("routed DstFrame carries the re-encoded value + a valid, fresh E2E trailer", function()
  local src = fromhex("64 00 00 00 00 00 00 00") -- Speed 10.0 km/h (raw 100 x0.1 @bit0 -> raw 10 x1 @bit8)
  local frames, tries = {}, 200
  while #frames < 4 and tries > 0 do
    bus.send("CAN1", 0x100, src)
    local f = bus.recv("CAN2", 20)
    if f and f.id == 0x200 then frames[#frames + 1] = f.data end
    tries = tries - 1
  end
  check.truthy(#frames >= 3, "received re-protected DstFrames, got " .. #frames)
  check.equal(string.byte(frames[1], 2), 0x0A) -- Speed raw 10 at bit8
  check.equal(string.byte(frames[1], 3), 0x00)
  for _, d in ipairs(frames) do -- CRC (byte7, crc_pos=6) matches an independent recompute
    check.equal(string.byte(d, 7), expected_crc(d, 0x2A, 8, 6))
  end
  -- the alive counter (low nibble of byte8, counter_pos=7) advances by EXACTLY ONE per
  -- frame — a delta > 1 is what e2e.RxState.check reports as a lost frame.
  for i = 2, #frames do
    local prev = string.byte(frames[i - 1], 8) & 0x0F
    local cur = string.byte(frames[i], 8) & 0x0F
    check.equal((cur - prev) & 0x0F, 1)
  end
end)

test("routed DstFrame2 is SecOC-authenticated with a valid AES-CMAC + one-step freshness", function()
  local src = fromhex("B8 0B 00 00 00 00 00 00") -- Rpm 3000 (0x0BB8) @bit0 -> @bit48 (bytes 6-7)
  local key = {}
  for i, b in ipairs({ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
                       0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f }) do key[i] = b end
  local DATA_ID, FRESH_POS, MAC_POS, MAC_LEN = 0x2B, 1, 2, 4 -- 0-based byte positions
  local frames, tries = {}, 200
  while #frames < 4 and tries > 0 do
    bus.send("CAN1", 0x101, src)
    local f = bus.recv("CAN2", 20)
    if f and f.id == 0x201 then frames[#frames + 1] = f.data end
    tries = tries - 1
  end
  check.truthy(#frames >= 3, "received SecOC DstFrame2s, got " .. #frames)
  check.equal(string.byte(frames[1], 7), 0xB8) -- Rpm survived
  check.equal(string.byte(frames[1], 8), 0x0B)
  for _, d in ipairs(frames) do
    -- recompute the CMAC over data_id(BE) + every frame byte EXCEPT the MAC bytes,
    -- truncate to MAC_LEN, and compare to the emitted MAC — a real receiver's check.
    local msg = { (DATA_ID >> 8) & 0xFF, DATA_ID & 0xFF }
    for i = 0, 7 do
      if i < MAC_POS or i >= MAC_POS + MAC_LEN then msg[#msg + 1] = string.byte(d, i + 1) end
    end
    local tag = cmac(key, msg)
    for i = 1, MAC_LEN do
      check.equal(string.byte(d, MAC_POS + i), tag[i]) -- emitted MAC byte == recomputed
    end
  end
  -- freshness (byte2, fresh_pos=1) advances by exactly one per frame
  for i = 2, #frames do
    check.equal((string.byte(frames[i], 2) - string.byte(frames[i - 1], 2)) & 0xFF, 1)
  end
end)
