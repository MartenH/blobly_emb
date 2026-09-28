-- Receive status (docs/diagnostics.md §3.2): BrakePressure arrives E2E-protected in BrakeStatus
-- (0x301: bytes 0-1 raw kPa x0.1, CRC byte 4, counter low nibble of byte 5, data_id 0x44). The
-- bridge publishes its RxStatus and the E2E lost-frame count; BrakeMonitor echoes what it SEES on
-- BrakeReport (0x131, every 50 ms: byte 0 status, bytes 1-2 lost, little-endian).
-- never_received is the enum's zero value (pinned by tools/loom2v's rx status test): it is only on
-- the wire in the first 300 ms after start, before any script of this suite can run.
-- @verifies REQ-COM-008
local OK, TIMEOUT, INTEGRITY = 1, 2, 3

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

local ctr = 0
-- the next BrakeStatus in sequence; `skip` frames are left out first (a gap), `corrupt` breaks the CRC
local function brake(raw, skip, corrupt)
  ctr = (ctr + 1 + (skip or 0)) & 0x0F
  local d = { raw & 0xFF, (raw >> 8) & 0xFF, 0, 0, 0, ctr }
  local b = { 0x44, 0x00 } -- CRC over data_id (lo, hi) + every byte except crc_pos (4)
  for i = 0, 5 do if i ~= 4 then b[#b + 1] = d[i + 1] end end
  d[5] = crc8(b)
  if corrupt then d[5] = d[5] ~ 0xFF end
  bus.send("CAN1", 0x301, string.char(table.unpack(d)))
end

-- the newest BrakeReport seen within `ms` (after dropping what was buffered before)
local function report(ms)
  while bus.recv("CAN1", 0) do end
  local last, t = nil, 0
  while t < ms do
    local f = bus.recv("CAN1", 10)
    if f and f.id == 0x131 then last = f.data end
    t = t + 10
  end
  check.truthy(last ~= nil, "no BrakeReport within " .. ms .. " ms")
  return string.byte(last, 1), string.byte(last, 2) + 256 * string.byte(last, 3)
end

test("RxStatus: a sender absent since start reaches timeout (the deadline runs from start)", function()
  local st = report(150) -- no script ever sends BrakeStatus before this one
  check.equal(st, TIMEOUT)
end)

test("RxStatus: good frames read ok, and a counter gap is counted as lost frames", function()
  for _ = 1, 5 do brake(1000); sleep_ms(10) end
  local st, lost0 = report(150)
  check.equal(st, OK)
  brake(1000, 2) -- two frames missing from the sequence
  sleep_ms(10)
  brake(1000)
  local st2, lost1 = report(150)
  check.equal(st2, OK)
  check.equal(lost1 - lost0, 2)
end)

test("RxStatus: a bad CRC reads integrity, silence then timeout, and a good frame ok again", function()
  brake(1000)
  brake(1000, 0, true)
  check.equal((report(150)), INTEGRITY) -- the deadline now runs from the bad frame (300 ms)
  sleep_ms(300) -- silence is now the newer fact
  check.equal((report(150)), TIMEOUT)
  brake(1000)
  check.equal((report(150)), OK)
end)
