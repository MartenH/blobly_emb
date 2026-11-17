-- @project ../system_full.blobnet
-- InputOutputControlByIdentifier (0x2F) on the target (docs/diagnostics.md §3.1 "Input/output
-- control"): the domain node (H755 CM7) controls two of the outputs it publishes — VehicleSpeed on
-- DID 0xF1A0 (VehSpeedFrame 0x120, an owner FB's, encoded by the comm thread's local producer) and
-- DynKeptOut on DID 0xF1A2 (DynKeptFrame 0x12C, the CM4's, sent by the comm thread from its lanes).
-- A tester's value replaces the FB's where the comm thread encodes the frame; PowertrainCtrl and
-- DynamicsModel keep computing theirs and never see it. Both controls: extended session, no 0x27
-- level, every parameter, each set, frozen, reset and returned. DynKeptOut is moved by the
-- protected DynCmd (0xFE000000 | v latches DynKept, test/xcore_domain.lua), which the watch
-- project's simulation never sends. Bench only: it needs the flashed board on the CANsub (system_full.blobnet),
-- so it is not in CI.
--   BLOBLY_NET=/path/to/blobly_net; v -enable-globals \
--     run $BLOBLY_NET/cmd/script/run.v examples/system_full/test/ioctl_domain.lua
-- Not tagged: comm/uds, comm/diag and tools/loom2v io_control_test.v verify REQ-DIAG-100..107 in CI,
-- and a bench script never runs in trace-check, so a tag would only ever read pending; this is their
-- on-bus evidence (a [[review]] in requirements/verifications.toml once run).
-- VehicleSpeed's DBC range is [0|250] (compute.dbc), so every value here stays at or below 250: a
-- larger one is refused 0x31, and nothing here can read as implausible on zone_a. Each test returns
-- control; a run aborted mid-test leaves an override in place only until S3 (5 s) or the next session
-- change. Before the ECUReset test, clear the core-reset vector catch a `st-flash
-- --connect-under-reset` left (the note in diag_nodes.lua), or 0x11 parks the node at its reset vector.

local SPEED, KEPT = 0xF1A0, 0xF1A2
local SPEED_ID, KEPT_ID = 0x120, 0x12C

local function diag()
  return uds.open("compute", { tx = 0x7B0, rx = 0x7B8 })
end

local function drain()
  while bus.recv("compute", 0) do end
end

-- a u32 little-endian at the start of a frame's payload (the wire), and big-endian (the DID / 0x2F)
local function le32(s)
  local b = { string.byte(s, 1, 4) }
  return b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216
end

local function be32(s)
  local b = { string.byte(s, 1, 4) }
  return ((b[1] * 256 + b[2]) * 256 + b[3]) * 256 + b[4]
end

local function u32be(v)
  return string.char((v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
end

-- the next `n` values frame `id` carries, after `skip_ms` of frames are let go (one sent before the
-- request took effect may still be queued)
local function wire(id, n, skip_ms)
  if skip_ms and skip_ms > 0 then
    sleep_ms(skip_ms)
  end
  drain()
  local out = {}
  for i = 1, n do
    out[i] = le32(expect("compute", id, 500).data)
  end
  return out
end

-- the protected command (E2E stamped per frame) every 50 ms, inside its 300 ms timeout: the watch
-- project never sends DynCmdFrame, so the CM4 hears only this
local function commander(x)
  return bus.send_message_cyclic("compute", "DynCmdFrame", { DynCmd = x }, 50)
end

-- the CM4's DynKept latched to `k` (a DynCmd of 0xFE000000 | k, test/xcore_domain.lua), seen on the
-- CM4 by its echo of the command — DynKeptFrame may be under control — then the command stopped
local function latch(k)
  local s = commander(0xFE000000 | k)
  expect_signal("compute", 0x129, "DynEcho", 0xFE000000 | k, 1000)
  sleep_ms(200) -- the latch reaches DynKeptOut
  s:stop()
end

-- a DynKept value in DynKeptOut's [0|16777215], nonzero and different every run
local function fresh()
  return (math.floor(now_ms()) * 2654435761) % 0xFFFFFF + 1
end

local function all_equal(vs, want, what)
  for _, v in ipairs(vs) do
    check.equal(v, want, what)
  end
end

-- PowertrainCtrl's own VehicleSpeed: 60 + tick % 40 + torque % 20, so 60..118, and it moves
local function fb_speeds(vs, what)
  local moved = false
  for i, v in ipairs(vs) do
    check.between(v, 60, 118, what)
    if i > 1 and v ~= vs[1] then
      moved = true
    end
  end
  check.truthy(moved, what .. ": the FB's value never moved: " .. table.concat(vs, ","))
end

test("ioctl: refused in the default session, and every malformed request by its NRC", function()
  local d = diag()
  d:session(0x01)
  check.nrc(0x7F, function() d:io_control(SPEED, 3, u32be(200)) end) -- not a default-session service
  d:session(0x03)
  check.nrc(0x13, function() d:raw("\x2F\xF1\xA0") end) -- shorter than four bytes
  check.nrc(0x31, function() d:io_control(0x0100, 3, u32be(1)) end) -- a DID with no control
  check.nrc(0x31, function() d:raw("\x2F\xF1\xA0\x04") end) -- no such parameter (raw: the client refuses one above 03)
  check.nrc(0x13, function() d:raw("\x2F\xF1\xA0\x03\x00\x00\xC8") end) -- a state of three bytes
  check.nrc(0x13, function() d:raw("\x2F\xF1\xA0\x00\xFF") end) -- a controlEnableMask
  check.nrc(0x13, function() d:raw("\x2F\xF1\xA0\x02\x00") end) -- 02 with a byte: length first
  check.nrc(0x31, function() d:io_control(SPEED, 3, u32be(251)) end) -- past compute.dbc's 250
  fb_speeds(wire(SPEED_ID, 5), "nothing refused took control")
  d:session(0x01)
end)

test("ioctl: 03 sets the value VehSpeedFrame carries, and the DID reads it", function()
  local d = diag()
  d:session(0x03)
  check.equal(tohex(d:io_control(SPEED, 3, u32be(200))), "00 00 00 C8")
  all_equal(wire(SPEED_ID, 6, 150), 200, "VehSpeedFrame under control")
  check.equal(be32(d:read_did(SPEED)), 200)
  check.equal(tohex(d:io_control(SPEED, 3, u32be(0))), "00 00 00 00") -- the range's low end
  all_equal(wire(SPEED_ID, 3, 150), 0, "VehSpeedFrame at 0")
  d:io_control(SPEED, 0)
  fb_speeds(wire(SPEED_ID, 6, 150), "control returned")
  d:session(0x01)
end)

test("ioctl: 02 freezes what is sent, 01 resets to the initial value, 00 gives the FB's back", function()
  local d = diag()
  d:session(0x03)
  local v = be32(d:io_control(SPEED, 2))
  check.between(v, 60, 118, "frozen at the FB's value")
  local held = wire(SPEED_ID, 11, 150) -- over a second, the FB moving every 50 ms
  all_equal(held, v, "VehSpeedFrame frozen")
  check.equal(be32(d:read_did(SPEED)), v)
  check.equal(tohex(d:io_control(SPEED, 1)), "00 00 00 00") -- VehicleSpeed's initial value
  all_equal(wire(SPEED_ID, 4, 150), 0, "VehSpeedFrame reset to default")
  local back = be32(d:io_control(SPEED, 0))
  check.between(back, 60, 118, "00 answers the FB's value")
  fb_speeds(wire(SPEED_ID, 6, 150), "control returned")
  d:session(0x01)
end)

test("ioctl: a return to the default session returns control", function()
  local d = diag()
  d:session(0x03)
  d:io_control(SPEED, 3, u32be(200))
  all_equal(wire(SPEED_ID, 2, 150), 200, "under control")
  d:session(0x01)
  fb_speeds(wire(SPEED_ID, 6, 150), "0x10 01 returned control")
end)

test("ioctl: S3 returns control", function()
  local d = diag()
  d:session(0x03)
  d:io_control(SPEED, 3, u32be(200))
  all_equal(wire(SPEED_ID, 2, 150), 200, "under control")
  sleep_ms(6000) -- s3_ms = 5000, nothing sent
  fb_speeds(wire(SPEED_ID, 6), "S3 returned control")
  check.nrc(0x7F, function() d:io_control(SPEED, 0) end) -- back in default
end)

test("ioctl: re-entering extended keeps an ungated control", function()
  local d = diag()
  d:session(0x03)
  d:io_control(SPEED, 3, u32be(200))
  d:session(0x03) -- re-entry relocks, and this control needs no level
  all_equal(wire(SPEED_ID, 4, 150), 200, "kept through the re-entry")
  d:io_control(SPEED, 0)
  fb_speeds(wire(SPEED_ID, 6, 150), "control returned")
  d:session(0x01)
end)

test("ioctl: an ECUReset returns control", function()
  local d = diag()
  d:session(0x03)
  d:io_control(SPEED, 3, u32be(200))
  all_equal(wire(SPEED_ID, 2, 150), 200, "under control")
  check.equal(tohex(d:raw("\x11\x01")), "51 01")
  sleep_ms(2000) -- the bootloader, then the application
  local after = wire(SPEED_ID, 8)
  for _, v in ipairs(after) do
    check.truthy(v ~= 200, "a control survived the reset: " .. table.concat(after, ","))
    check.truthy(v == 0 or (v >= 60 and v <= 118), "after the reset: the initial value or the FB's, got " .. v)
  end
  check.nrc(0x7F, function() d:io_control(SPEED, 0) end) -- the session is default after it
end)

-- the CM4's value: overridden where the CM7 comm thread sends DynKeptFrame, never on the CM4 (its
-- own DynKeptOut, and the persisted DynKept, stay what they were)
test("ioctl: a CM4 value is overridden where the CM7 sends it", function()
  local d = diag()
  d:session(0x03)
  local v = be32(d:read_did(KEPT))
  all_equal(wire(KEPT_ID, 2), v, "DynKeptFrame before")
  check.equal(tohex(d:io_control(KEPT, 3, u32be(0x00ABCDEF))), "00 AB CD EF")
  all_equal(wire(KEPT_ID, 4, 150), 0x00ABCDEF, "DynKeptFrame under control")
  check.equal(be32(d:read_did(KEPT)), 0x00ABCDEF)
  check.nrc(0x31, function() d:io_control(KEPT, 3, u32be(0x01000000)) end) -- past [0|16777215]
  check.equal(be32(d:io_control(KEPT, 0)), v) -- the CM4's value, untouched
  all_equal(wire(KEPT_ID, 3, 150), v, "DynKeptFrame after")
  d:session(0x01)
end)

-- 02 and 01 on the CM4's value: the freeze takes the value the CM7 sends (from its own reader of
-- the up channel) and holds the frame while the CM4's value moves; 01 sends DynKeptOut's initial
-- value; 00 gives the CM4's current value back
test("ioctl: a CM4 value frozen and reset where the CM7 sends it", function()
  local d = diag()
  local k = fresh()
  latch(k)
  all_equal(wire(KEPT_ID, 2), k, "DynKeptFrame at the latched value")
  d:session(0x03)
  check.equal(be32(d:io_control(KEPT, 2)), k, "frozen at the CM4's value")
  local k2 = (k ~ 0x00A5A5A5) % 0xFFFFFF + 1
  latch(k2) -- the CM4's DynKeptOut moves on
  all_equal(wire(KEPT_ID, 4, 150), k, "DynKeptFrame frozen while the CM4's value moved")
  check.equal(be32(d:read_did(KEPT)), k)
  check.equal(tohex(d:io_control(KEPT, 1)), "00 00 00 00") -- DynKeptOut's initial value
  all_equal(wire(KEPT_ID, 3, 150), 0, "DynKeptFrame reset to default")
  check.equal(be32(d:io_control(KEPT, 0)), k2, "00 answers the CM4's current value")
  all_equal(wire(KEPT_ID, 3, 150), k2, "DynKeptFrame back at the CM4's value")
  d:session(0x01)
end)

-- a functional 0x2F is ignored: an override is one ECU's, never every ECU's at once. A well-formed
-- 03 does not fit a single frame, so the request is a 02: served, it would freeze the FB's moving
-- value, which the check below would see
test("ioctl: a functional 0x2F is ignored", function()
  local d = diag()
  d:session(0x03)
  drain()
  bus.send("compute", 0x7DF, "\x04\x2F\xF1\xA0\x02\x00\x00\x00")
  sleep_ms(100)
  local f = bus.recv("compute", 0)
  while f do
    check.truthy(f.id ~= 0x7B8, "a functional 0x2F was answered: " .. tohex(f.data))
    f = bus.recv("compute", 0)
  end
  fb_speeds(wire(SPEED_ID, 5), "a functional 0x2F took control")
  d:session(0x01)
end)
