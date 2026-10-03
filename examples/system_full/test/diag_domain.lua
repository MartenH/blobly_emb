-- @project ../system_full.blobnet
-- UDS on the target (docs/diagnostics.md R2): the domain node (H755 CM7) serves ISO 14229 over
-- ISO-TP on the compute bus — requests on 0x7B0, answers on 0x7B8 — from its ThreadX comm thread,
-- while that thread keeps routing, telemetry and the tester's rest-bus traffic going. Bench only:
-- it needs the flashed board on the CANsub (system_full.blobnet), so it is not in CI.
--   BLOBLY_NET=/path/to/blobly_net; v -enable-globals -path "@vlib|@vmodules|$BLOBLY_NET/modules" \
--     run $BLOBLY_NET/cmd/script/run.v examples/system_full/test/diag_domain.lua
-- Recorded in requirements/verifications.toml (uds-on-target-domain, uds-on-target-live-did,
-- uds-on-target-security, uds-on-target-reset), not
-- tagged here: a bench
-- script never runs in trace-check, so a tag would only ever read pending.

local function diag()
  return uds.open("compute", { tx = 0x7B0, rx = 0x7B8 })
end

test("domain: tester present and the extended session", function()
  local d = diag()
  d:tester_present()
  local params = d:session(0x03)
  check.truthy(#params >= 4, "session answered with its P2/P2* timing")
  d:session(0x01)
end)

test("domain: a constant DID answers multi-frame", function()
  check.equal(diag():read_did(0xF190), "BLOBLY-DOMAIN-H755")
  check.equal(diag():read_did(0xF189), "system_full")
end)

-- a live DID answers what the node transmits: VehicleSpeed on 0x120, LedLevel on 0x126 (u32 LE on
-- the wire, u32 big-endian in the DID). The FB publishes every 50 ms and the node transmits every
-- 100 ms, so the DID may hold a value between two frames that never reaches the wire: it lies
-- within the frames around it, give or take the signal's own step per frame — measured from the
-- frames themselves. A window moving more than one period's worth is sampled again, so the slack
-- stays small enough that a DID stuck at 0, or reading another cell, cannot pass.
test("domain: a live DID answers what the node transmits", function()
  local d = diag()
  local function drain()
    while bus.recv("compute", 0) do end
  end
  local function wire(id)
    local f = expect("compute", id, 500)
    local b = { string.byte(f.data, 1, 4) }
    return b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216
  end
  local function did(id)
    local v = d:read_did(id)
    check.equal(#v, 4)
    local b = { string.byte(v, 1, 4) }
    return ((b[1] * 256 + b[2]) * 256 + b[3]) * 256 + b[4]
  end
  for _, p in ipairs({ { 0xF1A0, 0x120, "VehicleSpeed" }, { 0xF1A1, 0x126, "LedLevel" } }) do
    local before, now, after, step
    for _ = 1, 5 do
      drain()
      local prev = wire(p[2])
      before = wire(p[2])
      now = did(p[1])
      after = wire(p[2])
      step = math.max(math.abs(before - prev), math.abs(after - before))
      if step <= 150 then break end
    end
    log(string.format("%s: wire %d, DID %d, wire %d", p[3], before, now, after))
    check.truthy(step <= 150, p[3] .. " never held still enough to bracket")
    check.between(now, math.min(before, after) - step, math.max(before, after) + step,
      p[3] .. " DID follows the transmitted value")
  end
end)

test("domain: a RAM DID written reads back", function()
  local d = diag()
  d:write_did(0x0100, "\x12\x34\x56\x78")
  check.equal(tohex(d:read_did(0x0100)), "12 34 56 78")
end)

test("domain: a DID writable only in extended is refused in default", function()
  local d = diag()
  d:session(0x01)
  check.nrc(0x31, function() d:write_did(0x0101, "\x5A") end)
  d:session(0x03)
  d:write_did(0x0101, "\x5A")
  check.equal(tohex(d:read_did(0x0101)), "5A")
  d:session(0x01)
end)

test("domain: S3 returns an idle extended session to default", function()
  local d = diag()
  d:session(0x03)
  sleep_ms(6000) -- s3_ms = 5000
  check.nrc(0x31, function() d:write_did(0x0101, "\x00") end)
end)

test("domain: what the target does not serve is refused, not faked", function()
  local d = diag()
  d:session(0x01)
  -- programming is the bootloader handoff ([boot]): accepted from extended only, so never from
  -- default (boot_handoff.lua performs it)
  check.nrc(0x7E, function() d:session(0x02) end)
  check.nrc(0x31, function() d:read_did(0xABCD) end)
end)

-- 0x27 through the board's key seam (boards/common/diag_board.c): a TRNG seed, the reference key
test("domain: 0x27 unlocks a gated DID", function()
  local d = diag()
  check.nrc(0x7F, function() d:raw("\x27\x01") end) -- not a default-session service
  d:session(0x03)
  check.nrc(0x33, function() d:write_did(0x0102, "\x11") end) -- locked
  local s1 = d:raw("\x27\x01"):sub(3)
  local s2 = d:raw("\x27\x01"):sub(3)
  check.equal(#s1, 4)
  check.truthy(s1 ~= s2, "two seeds differ: " .. tohex(s1) .. " / " .. tohex(s2))
  -- one key per seed: a second key without a new seed is out of sequence
  local seed = d:raw("\x27\x01"):sub(3)
  check.nrc(0x35, function() d:raw("\x27\x02" .. seed) end) -- the seed is not its own key
  check.nrc(0x24, function() d:raw("\x27\x02" .. seed) end) -- and that seed is spent
  d:security_access(0x01) -- seed, then key = seed XOR 0xFF (a good key clears the count)
  d:write_did(0x0102, "\x11")
  check.equal(tohex(d:read_did(0x0102)), "11")
  d:session(0x01) -- relocks
  d:session(0x03)
  check.nrc(0x33, function() d:write_did(0x0102, "\x22") end)
  d:session(0x01)
end)

-- security_attempts = 3, security_delay_ms = 3000
test("domain: wrong keys lock 0x27 out for the delay", function()
  local d = diag()
  d:session(0x03)
  local wrong = function(seed) return seed end
  check.nrc(0x35, function() d:security_access(0x01, wrong) end)
  check.nrc(0x35, function() d:security_access(0x01, wrong) end)
  check.nrc(0x36, function() d:security_access(0x01, wrong) end)
  check.nrc(0x37, function() d:raw("\x27\x01") end) -- the delay runs
  sleep_ms(3200)
  d:tester_present()
  d:security_access(0x01) -- and after it, the right key unlocks
  d:session(0x01)
end)

-- a functional 0x27 is ignored: a broadcast key would spend a guess on every ECU
test("domain: a functional 0x27 is ignored", function()
  local d = diag()
  d:session(0x03)
  while bus.recv("compute", 0) do end
  bus.send("compute", 0x7DF, "\x02\x27\x01\x00\x00\x00\x00\x00")
  local answered = pcall(function() expect("compute", 0x7B8, 300) end)
  check.truthy(not answered, "a functional 0x27 was answered")
  d:tester_present() -- the physical connection is untouched
  d:session(0x01)
end)

-- 0x11 answered, THEN the node restarts: a RAM DID written before it is back at its initial value
-- (RAM re-initialised — a real restart, not a diagnostic-state reset) and the session is default
test("domain: ECUReset is answered, then the node restarts", function()
  local d = diag()
  d:write_did(0x0100, "\x12\x34\x56\x78")
  d:session(0x03)
  check.equal(tohex(d:raw("\x11\x01")), "51 01") -- the answer arrives before the reset
  sleep_ms(2000)
  check.equal(tohex(d:read_did(0x0100)), "00 00 00 00")
  check.nrc(0x31, function() d:write_did(0x0101, "\x01") end) -- the default session again
end)

-- the failed-key count survives the node's own reset (the keep cell, boards/common/diag_board.c):
-- a reset between guesses buys nothing
test("domain: wrong keys are still counted after a reset", function()
  local d = diag()
  d:session(0x03)
  local wrong = function(seed) return seed end
  check.nrc(0x35, function() d:security_access(0x01, wrong) end)
  check.nrc(0x35, function() d:security_access(0x01, wrong) end)
  d:raw("\x11\x01")
  sleep_ms(2000)
  d:session(0x03)
  check.nrc(0x37, function() d:raw("\x27\x01") end) -- the kept count armed the delay from boot
  sleep_ms(3200)
  d:tester_present()
  check.nrc(0x36, function() d:security_access(0x01, wrong) end) -- the THIRD wrong key, not a first
  sleep_ms(3200)
  d:tester_present()
  d:security_access(0x01) -- and the right key after the delay
  d:session(0x01)
end)

-- nor does a reset DURING a lockout: the lockout is kept (its count already zeroed), and runs on
test("domain: a lockout runs on through a reset", function()
  local d = diag()
  d:session(0x03)
  local wrong = function(seed) return seed end
  check.nrc(0x35, function() d:security_access(0x01, wrong) end)
  check.nrc(0x35, function() d:security_access(0x01, wrong) end)
  check.nrc(0x36, function() d:security_access(0x01, wrong) end) -- the lockout starts
  d:raw("\x11\x01")
  sleep_ms(2000)
  d:session(0x03)
  check.nrc(0x37, function() d:raw("\x27\x01") end) -- still locked out after the restart
  sleep_ms(3200)
  d:tester_present()
  d:security_access(0x01)
  d:session(0x01)
end)

-- The server shares the comm thread with the node's application traffic: a burst of multi-frame
-- answers must not starve VehSpeedFrame (0x120, every 100 ms).
test("domain: requests back to back while the node keeps its cadence", function()
  local d = diag()
  local function drain()
    local n = 0
    local f = bus.recv("compute", 0)
    while f do
      if f.id == 0x120 and not f.ext then n = n + 1 end
      f = bus.recv("compute", 0)
    end
    return n
  end
  drain()
  -- __now_ms is the prelude's own clock (expect() waits on it); it has no public name yet
  local t0 = __now_ms()
  local seen, reads = 0, 0
  while __now_ms() - t0 < 3000 do
    check.equal(d:read_did(0xF190), "BLOBLY-DOMAIN-H755")
    reads = reads + 1
    seen = seen + drain()
  end
  local ms = __now_ms() - t0
  local want = math.floor(ms / 100)
  log(string.format("%d reads in %d ms; VehSpeedFrame %d of ~%d", reads, ms, seen, want))
  check.truthy(seen >= want * 0.9, "VehSpeedFrame kept its 100 ms cadence during the burst")
end)
