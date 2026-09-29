-- @project ../system_full.blobnet
-- UDS on the target (docs/diagnostics.md R2): the domain node (H755 CM7) serves ISO 14229 over
-- ISO-TP on the compute bus — requests on 0x7B0, answers on 0x7B8 — from its ThreadX comm thread,
-- while that thread keeps routing, telemetry and the tester's rest-bus traffic going. Bench only:
-- it needs the flashed board on the CANsub (system_full.blobnet), so it is not in CI.
--   BLOBLY_NET=/path/to/blobly_net; v -enable-globals -path "@vlib|@vmodules|$BLOBLY_NET/modules" \
--     run $BLOBLY_NET/cmd/script/run.v examples/system_full/test/diag_domain.lua
-- Recorded in requirements/verifications.toml (uds-on-target-domain, uds-on-target-live-did), not
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
-- the wire, u32 big-endian in the DID). Read between two frames it lies between them, give or take
-- the step the frames themselves show (a turning point may fall inside the window) — so a DID
-- stuck at 0, or reading another cell, cannot pass unless the wire says the same.
test("domain: a live DID answers what the node transmits", function()
  local d = diag()
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
    local before = wire(p[2])
    local now = did(p[1])
    local after = wire(p[2])
    log(string.format("%s: wire %d, DID %d, wire %d", p[3], before, now, after))
    local step = math.abs(after - before)
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

test("domain: what the target does not serve yet is refused, not faked", function()
  local d = diag()
  check.nrc(0x11, function() d:raw("\x11\x01") end) -- no reset performed on the target yet
  check.nrc(0x11, function() d:raw("\x27\x01") end) -- no key seam yet
  check.nrc(0x12, function() d:session(0x02) end)   -- programming: the bootloader handoff
  check.nrc(0x31, function() d:read_did(0xABCD) end)
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
