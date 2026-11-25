-- RoutineControl (0x31) on the host bridge (docs/diagnostics.md §3.1 "Routines"): overspeed's
-- SelfCheck routine (0x0201, sync, one option byte = steps of 100 ms, its answer the dispatches
-- counted as a u16 big-endian, results offered) is run by the SelfChecker FB on ctrl_main, while the
-- diagnostic bridge answers responsePending (0x78) until the FB has reported. Drives the requests,
-- the 0x78s on the bus and the final answers end to end. Not tagged: the rules are comm/uds and
-- comm/diag's unit tests' (REQ-DIAG-080 .. REQ-DIAG-085); this is their on-bus evidence.
--   make all && sudo make vcan && make test BLOBLY_NET=/path/to/blobly_net   (examples/overspeed)

local REQ_ID = 0x101
local RSP_ID = 0x102
local SELF_CHECK = 0x0201

local function diag() return uds.open("CAN1", { tx = REQ_ID, rx = RSP_ID }) end

local function u16(s, at) return (string.byte(s, at) << 8) | string.byte(s, at + 1) end

-- the extended session; then the first wait at 200 ms (a 0x10 answer loosens it to P2 + margin,
-- which would hide a missing 0x78)
local function extended(d)
  d:session(0x03)
  d:set_timing({ timeout_ms = 200 })
end

local function drain()
  while bus.recv("CAN1", 0) do end
end

-- how many responsePending single frames (03 7F 31 78) are queued on the response id
local function pendings()
  local n = 0
  while true do
    local f = bus.recv("CAN1", 0)
    if not f then break end
    if f.id == RSP_ID and f.data:sub(1, 4) == "\x03\x7F\x31\x78" then
      n = n + 1
    end
  end
  return n
end

test("routine: a 2 s self-check answers done after one responsePending", function()
  local d = diag()
  extended(d)
  drain() -- and subscribes the script's own handle to the bus
  local t0 = now_ms()
  local r = d:routine(SELF_CHECK, "\x14") -- 20 steps of 100 ms
  check.equal(string.byte(r, 1), 2, "routineInfo: done")
  check.equal(u16(r, 2), 40, "the dispatches it counted")
  check.truthy(now_ms() - t0 >= 1900, "it ran its 2 s: " .. (now_ms() - t0) .. " ms")
  check.equal(pendings(), 1, "one 0x78, at once (the next would come at 4 s)")
end)

test("routine: the final answer comes even under the suppress bit", function()
  local d = diag()
  extended(d)
  local t0 = now_ms()
  -- false: the server answered 0x78, so the positive answer was owed — not a bit it ignored
  check.equal(d:raw_suppressed("\x31\x81\x02\x01\x0A"), false)
  check.truthy(now_ms() - t0 >= 900, "it waited for the 1 s check: " .. (now_ms() - t0) .. " ms")
end)

test("routine: results read the last check again", function()
  local d = diag()
  extended(d)
  check.equal(string.byte(d:routine(SELF_CHECK, "\x03"), 1), 2)
  local r = d:routine(SELF_CHECK, nil, 3)
  check.equal(string.byte(r, 1), 2, "done")
  check.equal(u16(r, 2), 6)
end)

test("routine: refusals", function()
  local d = diag()
  extended(d)
  check.nrc(0x13, function() d:routine(SELF_CHECK) end) -- its option record is one byte
  check.nrc(0x31, function() d:routine(SELF_CHECK, "\x00") end) -- the FB refuses 0 steps, after 0x78
  check.nrc(0x12, function() d:routine(SELF_CHECK, nil, 2) end) -- a sync routine offers no stop
  check.nrc(0x31, function() d:routine(0x0300, "\x01") end) -- no such routine
  d:session(0x01)
  check.nrc(0x31, function() d:routine(SELF_CHECK, "\x01") end) -- not in the default session
end)
