-- @project diag_bench.blobnet
-- ROUTINES on the target (docs/diagnostics.md §3.1 "Routines"): zone_a (H723, the CAN-FD edge bus,
-- requests on 0x7C0, answers on 0x7C8) serves RoutineControl (0x31) for two [[routine]]s run by its
-- RoutineRunner FB on front_thread, while its comm thread answers responsePending (0x78) — at once,
-- then every 4 s — until the FB has reported:
--   0x0201 ActuatorSelfTest (sync): option N runs N x 100 ms; answered done with the dispatches it
--     counted (u16 big-endian); option 0 refused 0x31; past timeout_ms (10 s) answered 0x22.
--   0x0202 SensorCalibration (async, stop, results, level 1): answered running at once; 0x31 03 reads
--     the count rising to 100 (5 s), done; 0x31 02 stops it.
-- And the gateway: sysnode forwards each 0x78 of a routed 9 s self-test to its DoIP tester.
--
-- Bench only (zone_a flashed with its bootloader — `make flash` in nodes/zone_a — on the CANsub, edge =
-- channel 1; sysnode on the LAN for the last test):
--   BLOBLY_NET=/path/to/blobly_net; v -enable-globals \
--     run $BLOBLY_NET/cmd/script/run.v examples/system_full/test/routine_zone_a.lua
-- Recorded in requirements/verifications.toml by the bench run (REQ-DIAG-080 .. REQ-DIAG-086), not
-- tagged here: a bench script never runs in trace-check, so a tag would only ever read pending.
-- It begins with an ECUReset of zone_a, so "results before any start" holds on a re-run.

local REQ_ID = 0x7C0
local RSP_ID = 0x7C8
local SELF_TEST = 0x0201
local CALIBRATION = 0x0202
local BOOT_MS = 3000 -- the bootloader's check, the application's start, the journal's mount
local REPEAT_MS = 4000 -- uds.pending_repeat_us: P2*server_max less its 1 s margin
local SLACK_MS = 500
local ZONE_A_LOGICAL = 0x07C0 -- zone_a behind sysnode's DoIP entity (system.toml)

local function diag() return uds.open("edge", { tx = REQ_ID, rx = RSP_ID }) end

-- every session change resets the client's first wait to the server's P2 + margin (1050 ms): stated
-- again at 200 ms, so a missing 0x78 shows as a timeout
local function session(d, sub)
  d:session(sub)
  d:set_timing({ timeout_ms = 200 })
end

local function unlock(d)
  session(d, 0x03)
  d:security_access(1) -- zone_a's bench key is blobly_net's reference key
end

local function drain()
  while bus.recv("edge", 0) do end
end

local function reset(d)
  d:reset(0x01)
  sleep_ms(BOOT_MS)
  drain() -- what queued across the restart is the old run's
end

local function u16(s, at) return (string.byte(s, at) << 8) | string.byte(s, at + 1) end

-- a single frame on the request id, as a tester puts one on the wire
local function send_sf(req) bus.send("edge", REQ_ID, string.char(#req) .. req) end

-- the payload of a single frame zone_a answered (nil for any other frame)
local function sf_payload(f)
  local pci = string.byte(f.data, 1)
  if f.id ~= RSP_ID or (pci >> 4) ~= 0 then return nil end
  return f.data:sub(2, 1 + (pci & 0x0F))
end

local PENDING = "\x7F\x31\x78"

-- one raw exchange: `req` sent as a single frame, then every single-frame answer on 0x7C8 read with
-- its time (ms after the request) until one is not a responsePending or `max_ms` runs out. Returns
-- the times of the responsePending answers and the final answer with its time.
local function exchange(req, max_ms)
  drain()
  local t0 = now_ms()
  send_sf(req)
  local pendings = {}
  while now_ms() - t0 < max_ms do
    local f = bus.recv("edge", 50)
    local p = f and sf_payload(f)
    if p then
      local t = now_ms() - t0
      if p == PENDING then
        pendings[#pendings + 1] = t
      else
        return pendings, p, t
      end
    end
  end
  return pendings, nil, nil
end

-- responsePending at once, then every 4 s (each measured from the one before)
local function check_cadence(pendings)
  check.truthy(pendings[1] < SLACK_MS, "the first 0x78 within P2: " .. pendings[1] .. " ms")
  for i = 2, #pendings do
    local gap = pendings[i] - pendings[i - 1]
    check.truthy(math.abs(gap - REPEAT_MS) <= SLACK_MS, "0x78 " .. i .. " came " .. gap .. " ms after the one before")
  end
end

test("routines: zone_a restarts clean", function()
  reset(diag())
end)

test("routines: a 2 s self-test is answered done after responsePending", function()
  local d = diag()
  session(d, 0x03)
  local t0 = now_ms()
  local r = d:routine(SELF_TEST, "\x14") -- 20 steps of 100 ms
  check.equal(string.byte(r, 1), 2, "routineInfo: done")
  check.equal(u16(r, 2), 40, "the dispatches it counted")
  check.truthy(now_ms() - t0 >= 1900, "it ran its 2 s: " .. (now_ms() - t0) .. " ms")
  check.equal(string.byte(d:routine(SELF_TEST, "\x01"), 1), 2, "a second start: done again")
end)

test("routines: a 9 s self-test sends 0x78 at once, then every 4 s, then its answer", function()
  local d = diag()
  session(d, 0x03)
  local pendings, ans, t = exchange("\x31\x01\x02\x01\x5A", 15000) -- 90 steps: 9 s
  check.equal(#pendings, 3, "0x78 at 0, 4 and 8 s")
  check_cadence(pendings)
  check.equal(ans, "\x71\x01\x02\x01\x02\x00\xB4", "done, 180 dispatches")
  check.truthy(math.abs(t - 9000) <= 1000, "answered when done: " .. t .. " ms")
end)

test("routines: the final answer is sent even under the suppress bit", function()
  local d = diag()
  session(d, 0x03)
  local t0 = now_ms()
  check.equal(d:raw_suppressed("\x31\x81\x02\x01\x0A"), false, "after 0x78 the positive answer was owed")
  check.truthy(now_ms() - t0 >= 900, "it waited for the routine: " .. (now_ms() - t0) .. " ms")
end)

test("routines: refusals in ISO 14229-1's order", function()
  local d = diag()
  session(d, 0x01)
  check.nrc(0x31, function() d:routine(SELF_TEST, "\x14") end) -- not allowed in default
  session(d, 0x03)
  check.nrc(0x13, function() d:raw("\x31\x01\x02") end) -- shorter than 4
  check.nrc(0x12, function() d:raw("\x31\x04\x02\x01") end) -- no such sub-function
  check.nrc(0x31, function() d:routine(0x0300) end) -- no such routine
  check.nrc(0x12, function() d:routine(SELF_TEST, nil, 2) end) -- a sync routine offers no stop
  check.nrc(0x13, function() d:routine(SELF_TEST) end) -- its option record is one byte
  check.nrc(0x33, function() d:routine(CALIBRATION) end) -- level 1, locked
  check.nrc(0x31, function() d:routine(SELF_TEST, "\x00") end) -- the FB's own refusal, after 0x78
end)

test("routines: a self-test past its timeout is answered 0x22, and the next one runs", function()
  local d = diag()
  session(d, 0x03)
  local pendings, ans, t = exchange("\x31\x01\x02\x01\xFF", 15000) -- 25.5 s: past the 10 s timeout
  check.equal(ans, "\x7F\x31\x22", "conditionsNotCorrect at the timeout")
  check.truthy(math.abs(t - 10000) <= 1000, "at 10 s: " .. tostring(t) .. " ms")
  check.equal(#pendings, 3)
  check_cadence(pendings)
  check.equal(string.byte(d:routine(SELF_TEST, "\x14"), 1), 2, "the FB was stopped: a new start runs")
end)

test("routines: an async calibration — start, results, stop", function()
  local d = diag()
  unlock(d)
  check.nrc(0x24, function() d:routine(CALIBRATION, nil, 3) end) -- results before any start
  check.equal(string.byte(d:routine(CALIBRATION), 1), 1, "answered running at once")
  local a = d:routine(CALIBRATION, nil, 3)
  check.equal(string.byte(a, 1), 1)
  sleep_ms(500)
  local b = d:routine(CALIBRATION, nil, 3)
  check.equal(string.byte(b, 1), 1)
  check.truthy(u16(b, 2) > u16(a, 2), "the count rises: " .. u16(a, 2) .. " then " .. u16(b, 2))
  check.nrc(0x24, function() d:routine(CALIBRATION) end) -- a start while running
  check.equal(string.byte(d:routine(CALIBRATION, nil, 2), 1), 3, "stopped")
  check.equal(string.byte(d:routine(CALIBRATION, nil, 3), 1), 3, "results: stopped")
  check.nrc(0x24, function() d:routine(CALIBRATION, nil, 2) end) -- a stop while not running
end)

test("routines: the calibration runs to done", function()
  local d = diag()
  unlock(d)
  check.equal(string.byte(d:routine(CALIBRATION), 1), 1)
  local r
  for _ = 1, 20 do -- 10 s at most; each 03 keeps the session alive
    sleep_ms(500)
    r = d:routine(CALIBRATION, nil, 3)
    if string.byte(r, 1) ~= 1 then break end
  end
  check.equal(string.byte(r, 1), 2, "done")
  check.equal(u16(r, 2), 100)
end)

test("routines: re-entering the session stops a running calibration", function()
  local d = diag()
  unlock(d)
  check.equal(string.byte(d:routine(CALIBRATION), 1), 1)
  unlock(d) -- 0x10 03 again: a routine does not outlive its session instance
  sleep_ms(300) -- the FB's next dispatch answers the server's stop
  check.equal(string.byte(d:routine(CALIBRATION, nil, 3), 1), 3, "stopped by the session entry")
end)

test("routines: a request while an answer is owed is dropped", function()
  local d = diag()
  session(d, 0x03)
  drain()
  local t0 = now_ms()
  send_sf("\x31\x01\x02\x01\x14") -- 2 s
  local first
  while not first and now_ms() - t0 < 1000 do
    local f = bus.recv("edge", 50)
    first = f and sf_payload(f)
  end
  check.equal(first, PENDING)
  send_sf("\x3E\x00")
  local tp_at = now_ms()
  local final
  while not final and now_ms() - t0 < 5000 do
    local f = bus.recv("edge", 50)
    local p = f and sf_payload(f)
    if p == "\x7E\x00" then
      check.truthy(false, "TesterPresent answered " .. (now_ms() - tp_at) .. " ms after it, while an answer was owed")
    elseif p and p ~= PENDING then
      final = p
    end
  end
  check.equal(final, "\x71\x01\x02\x01\x02\x00\x28", "the routine's answer, done, 40 dispatches")
end)

test("routines: through the gateway, a 9 s self-test with its 0x78s", function()
  local g = uds.open("sysnode_ip")
  g:session(0x03)
  g:security_access(0x01) -- the gateway's own unlock: routing needs it (REQ-NET-020)
  g:retarget(ZONE_A_LOGICAL)
  g:session(0x03) -- zone_a's session, through the gateway
  drain()
  local t0 = now_ms()
  local r = g:routine(SELF_TEST, "\x5A") -- 9 s: longer than the gateway's 6 s wait
  check.equal(string.byte(r, 1), 2, "done")
  check.equal(u16(r, 2), 180)
  check.truthy(now_ms() - t0 >= 8500, "answered when done: " .. (now_ms() - t0) .. " ms")
  local n = 0
  while true do
    local f = bus.recv("edge", 0)
    if not f then break end
    if sf_payload(f) == PENDING then n = n + 1 end
  end
  check.equal(n, 3, "zone_a answered 0x78 three times on edge")
end)
