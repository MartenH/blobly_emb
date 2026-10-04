-- @project diag_bench.blobnet
-- @verifies REQ-DIAG-017
-- A PARAMETER on the target (docs/diagnostics.md §3.4, R7): zone_a (H723, the edge bus) codes the
-- SteerLimit parameter — the most its SteerLimiter puts on the wire as SteeringAngle — with 0x2E on
-- DID 0x0110 (extended session, 0x27 level 1), keeps it in the NvM journal (boards/h723/bootmap.h,
-- flash sectors 6 + 7) and reads it back with 0x22. It is declared apply = "reset": a coded limit
-- takes effect at the next start, so the suite codes it, sees the bus unchanged, resets, and sees
-- SteeringAngle held to the coded limit. The status DID 0x0111 says coded (1) or default (0).
--
-- Bench only (zone_a flashed with its bootloader — `make flash` in nodes/zone_a — on the CANsub,
-- edge = channel 1; the domain and the gateway running, so VehicleSpeed reaches zone_a):
--   BLOBLY_NET=/path/to/blobly_net; v -enable-globals -path "@vlib|@vmodules|$BLOBLY_NET/modules" \
--     run $BLOBLY_NET/cmd/script/run.v examples/system_full/test/param_zone_a.lua
-- The power-cut test runs only when BLOB_ZONE_A_POWER_CUT names a command that cuts zone_a's power
-- (or resets it with no warning to the firmware, e.g. `st-flash --serial $BLOB_H723_SERIAL reset`)
-- and returns once it is back; without it that test logs that it was skipped. The suite leaves
-- zone_a coded to 360, the no-limit value.

local LIMIT_DID = 0x0110
local STATUS_DID = 0x0111
local STEER_ID = 0x132 -- SteeringFrame (edge.dbc): SteeringAngle, u32 LE at bit 0, every 50 ms
local BOOT_MS = 3000 -- the bootloader's check, the application's start, the journal's mount
local NO_LIMIT = 360

local function diag() return uds.open("edge", { tx = 0x7C0, rx = 0x7C8 }) end

local function unlock(d)
  d:session(0x03)
  d:security_access(1) -- zone_a's bench key is blobly_net's reference key
end

local function u16(v) return frombytes({ (v >> 8) & 0xFF, v & 0xFF }) end

local function reset(d)
  d:reset(0x01)
  sleep_ms(BOOT_MS)
  while bus.recv("edge", 0) do end -- what queued across the restart is the old run's
end

-- the largest SteeringAngle zone_a transmits over `frames` SteeringFrames (the raw sweep steps 5°
-- every 50 ms: 72 frames are one whole sweep, 0..355)
local function max_angle(frames)
  local seen, max, polls = 0, -1, 0
  while seen < frames do
    polls = polls + 1
    check.truthy(polls < 20 * frames, "zone_a stopped sending SteeringFrame")
    local f = bus.recv("edge", 200)
    if f ~= nil and f.id == STEER_ID then
      local a = string.byte(f.data, 1) | (string.byte(f.data, 2) << 8)
        | (string.byte(f.data, 3) << 16) | (string.byte(f.data, 4) << 24)
      if a > max then max = a end
      seen = seen + 1
    end
  end
  return max
end

-- code `deg` and restart, so the limiter runs on it
local function coded(deg)
  local d = diag()
  unlock(d)
  d:write_did(LIMIT_DID, u16(deg))
  reset(d)
  return diag()
end

test("zone_a: uncoded, or coded to the no-limit value, SteeringAngle sweeps past 100", function()
  local d = coded(NO_LIMIT)
  check.equal(tohex(d:read_did(LIMIT_DID)), tohex(u16(NO_LIMIT)))
  local m = max_angle(80)
  log(string.format("SteeringAngle max %d over a sweep, limit %d", m, NO_LIMIT))
  check.truthy(m > 100, "the sweep never passed 100 with no limit coded: " .. m)
end)

test("zone_a: a write is gated by the DID's session and level, and validated before storage", function()
  local d = diag()
  d:session(0x01)
  check.nrc(0x31, function() d:write_did(LIMIT_DID, u16(100)) end) -- not writable in default
  d:session(0x03)
  check.nrc(0x33, function() d:write_did(LIMIT_DID, u16(100)) end) -- no 0x27 level 1 yet
  d:security_access(1)
  check.nrc(0x31, function() d:write_did(LIMIT_DID, u16(361)) end) -- outside 0..360
  check.nrc(0x13, function() d:write_did(LIMIT_DID, "\x64") end) -- one byte of a u16
  check.equal(tohex(d:read_did(LIMIT_DID)), tohex(u16(NO_LIMIT)), "a refused write changed the coding")
  check.nrc(0x31, function() d:write_did(STATUS_DID, "\x00") end) -- the status is read-only
end)

test("zone_a: a coded limit takes effect at the next start, and holds SteeringAngle to it", function()
  local d = diag()
  unlock(d)
  d:write_did(LIMIT_DID, u16(100))
  check.equal(tohex(d:read_did(LIMIT_DID)), tohex(u16(100))) -- 0x22 reads the coded value at once
  check.equal(string.byte(d:read_did(STATUS_DID), 1), 1, "the status does not say coded")
  -- apply = "reset": the limiter keeps the limit it started with until the next start
  local before = max_angle(80)
  log(string.format("after the write, before the reset: SteeringAngle max %d", before))
  check.truthy(before > 100, "the coded limit applied before the reset: " .. before)
  reset(d)
  d = diag()
  check.equal(tohex(d:read_did(LIMIT_DID)), tohex(u16(100)), "the coding did not survive the reset")
  check.equal(string.byte(d:read_did(STATUS_DID), 1), 1)
  local after = max_angle(80)
  log(string.format("after the reset: SteeringAngle max %d, limit 100", after))
  check.equal(after, 100, "SteeringAngle is not held to the coded 100")
  -- the live DID agrees with the wire
  local live = d:read_did(0xF1A0)
  check.truthy((string.byte(live, 3) << 8 | string.byte(live, 4)) <= 100, "0xF1A0 reads past the limit")
end)

test("zone_a: a power cut with no warning keeps the coding the tester was answered for", function()
  local cmd = os.getenv("BLOB_ZONE_A_POWER_CUT")
  if cmd == nil or cmd == "" then
    log("skipped: set BLOB_ZONE_A_POWER_CUT to a command that cuts zone_a's power and restores it")
    return
  end
  local d = diag()
  unlock(d)
  d:write_did(LIMIT_DID, u16(150)) -- durable before this answer arrived
  check.truthy(os.execute(cmd), "the power-cut command failed: " .. cmd)
  sleep_ms(BOOT_MS)
  while bus.recv("edge", 0) do end
  d = diag()
  check.equal(tohex(d:read_did(LIMIT_DID)), tohex(u16(150)))
  check.equal(max_angle(80), 150)
end)

test("zone_a: coded back to the no-limit value, the sweep is whole again", function()
  local d = coded(NO_LIMIT)
  check.equal(tohex(d:read_did(LIMIT_DID)), tohex(u16(NO_LIMIT)))
  check.truthy(max_angle(80) > 100)
end)
