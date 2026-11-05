-- @project diag_bench.blobnet
-- Signals across the domain node's two cores (docs/xcore.md), read off the compute bus — each
-- CM7 -> CM4 shape once, each echoed back by the CM4's DynamicsModel:
--   DynCmd (DynCmdFrame 0x124, from this script as the tester) is PROTECTED (E2E Profile 1, Data ID
--     0x56, 300 ms timeout): the CM7 comm thread checks every frame and hands the value DOWN to the
--     CM4 with its receive status. The CM4 sends it back as DynEcho (0x129) while the status is ok,
--     and 0xFFFFFF00 | status otherwise — so a timeout and a corrupt frame are seen ON THE CM4.
--   HostLedLevel (HostLedFrame 0x127) is read by PowertrainCtrl on the CM7 and by the CM4: one lean
--     decode feeds both, and the CM4 sends it back as DynLed (0x12B).
--   PtState is a CM7 FB output (seq = its tick count, inv = the complement, two lanes of one
--     channel); the CM4 reports DynPt = seq when the lanes agree, 0xFFFFFFFF when they tore,
--     0 before the first publish (0x12A).
-- Bench only (the flashed board on the CANsub), so not in CI.
--
-- Not the watch project (../system_full.blobnet): its tester simulation transmits tester frames
-- with a cycle (HostLedFrame among them), which would fight the values this script sends.
-- diag_bench.blobnet transmits nothing of its own on compute.
--
-- Prerequisites: BOTH banks flashed from ONE build — domain (bank 1) and domain_m4 (bank 2,
-- 0x08100000). The layout id gates every cross-core channel, so a mismatched pair shows as the
-- first test failing (no DynEchoFrame at all), never as wrong values:
--   make -C examples/system_full/nodes/domain    flash SERIAL=<H755 sn>
--   make -C examples/system_full/nodes/domain_m4 flash SERIAL=<H755 sn>
-- After flashing with `st-flash --connect-under-reset`, clear the core-reset vector catch before
-- the reset test (the note in diag_nodes.lua), or 0x11 parks the CM7 at its reset vector.
--   BLOBLY_NET=/path/to/blobly_net; v -enable-globals \
--     run $BLOBLY_NET/cmd/script/run.v examples/system_full/test/xcore_domain.lua
-- Recorded in requirements/verifications.toml, not tagged here: a bench script never runs in
-- trace-check, so a tag would only ever read pending. An owner reset beside a LIVE satellite (the
-- nonce and the gate retracting) is not reachable here — 0x11 resets both cores — and is proven on
-- the host against a fake SRAM4 (tools/xioc/xcore_down_test.v).

local CH = "compute"
-- DynEcho when the CM4 has no good command: 0xFFFFFF00 | the RxStatus it was handed
local TIMEOUT, INTEGRITY = 0xFFFFFF02, 0xFFFFFF03

local function drain()
  while bus.recv(CH, 0) do end
end
local function value(id, signal, ms)
  local f = expect(CH, id, ms or 500)
  return decode(CH, f.id, f.data, f.ext)[signal], f
end
-- nonzero, below the status codes, and different every run, so nothing left from an earlier run
-- can pass
local function fresh()
  return (math.floor(now_ms()) * 2654435761) % 0xFFFFFE00 + 1
end
-- the protected command, sent every 50 ms (inside the 300 ms timeout), E2E stamped per frame
local function commander(x)
  return bus.send_message_cyclic(CH, "DynCmdFrame", { DynCmd = x }, 50)
end

-- the CM4's frames go out from boot like any other (the initial payload until its first value), so
-- what shows the CM4 running is DynPt ADVANCING: it carries the CM7's tick through the CM4, and only
-- a running CM4 of the same build (the layout gate) moves it
test("xcore: the CM4 is up and both banks are one build", function()
  local a = value(0x12A, "DynPt", 1000)
  sleep_ms(500)
  drain()
  local b = value(0x12A, "DynPt", 1000)
  check.truthy(b > a and b ~= 0xFFFFFFFF, string.format("DynPt %d then %d: the CM4 is not running, or the banks are from different builds (flash both)", a, b))
end)

test("xcore: a protected bus command crosses to the CM4 and back", function()
  local x = fresh()
  drain()
  local t0 = now_ms()
  local s = commander(x)
  expect_signal(CH, 0x129, "DynEcho", x, 1000)
  log(string.format("DynCmd 0x%08X echoed within %.1f ms", x, now_ms() - t0))
  local y = (x ~ 0x5A5A5A5A) % 0xFFFFFE00 + 1
  s:update({ DynCmd = y })
  expect_signal(CH, 0x129, "DynEcho", y, 1000)
  s:stop()
end)

test("xcore: the CM7's timeout reaches the CM4 when the sender stops", function()
  local s = commander(fresh())
  expect(CH, 0x129, 1000)
  sleep_ms(200)
  s:stop()
  local t0 = now_ms()
  expect_signal(CH, 0x129, "DynEcho", TIMEOUT, 1500)
  log(string.format("timeout seen on the CM4 %.0f ms after the last command (deadline 300 ms)", now_ms() - t0))
end)

test("xcore: a corrupt frame reaches the CM4 as an integrity failure", function()
  local x = fresh()
  local s = commander(x)
  expect_signal(CH, 0x129, "DynEcho", x, 1000)
  s:stop()
  -- protected properly, then the CRC byte inverted: wrong by construction
  local f = e2e.p01_protect(string.pack("<I4", x) .. "\0\0\0\0", 0x56, 4, 5, 0)
  local bad = f:sub(1, 4) .. string.char(f:byte(5) ~ 0xFF) .. f:sub(6)
  local b = bus.send_cyclic(CH, 0x124, bad, 50)
  expect_signal(CH, 0x129, "DynEcho", INTEGRITY, 1000)
  b:stop()
end)

test("xcore: one lean decode feeds the CM7 and the CM4", function()
  local v = math.floor(now_ms()) % 999 + 1
  local s = bus.send_message_cyclic(CH, "HostLedFrame", { HostLedLevel = v }, 100)
  expect_signal(CH, 0x12B, "DynLed", v, 1000)
  s:stop()
end)

-- seq is the CM7 FB tick (50 ms), so it rises ~20 a second; 0xFFFFFFFF would be a read that mixed
-- two publishes across the channel lanes
test("xcore: a CM7 FB output crosses to the CM4, both lanes together", function()
  drain()
  local first, f1 = value(0x12A, "DynPt")
  local last, fl = first, f1
  local n = 1
  while fl.t_ms - f1.t_ms < 2000 do
    check.truthy(last ~= 0xFFFFFFFF, "torn PtState lanes (DynPt 0xFFFFFFFF)")
    local v, f = value(0x12A, "DynPt")
    check.truthy(v >= last, string.format("DynPt went back: %d after %d", v, last))
    last, fl, n = v, f, n + 1
  end
  check.truthy(last ~= 0xFFFFFFFF, "torn PtState lanes (DynPt 0xFFFFFFFF)")
  local rate = (last - first) * 1000 / (fl.t_ms - f1.t_ms)
  log(string.format("DynPt %d -> %d over %d frames: %.1f per second", first, last, n, rate))
  check.between(rate, 17, 23, "PtState.seq per second (the CM7 50 ms tick)")
end)

-- SRAM4 is retained through a reset: a CM7 boot that skipped re-arming the owner window would
-- leave the old gate open and the old values in it, and the rebooted CM4 would echo what nobody
-- sent since
test("xcore: a reset does not bring back the retained values", function()
  local z = fresh()
  local s = commander(z)
  local l = bus.send_message_cyclic(CH, "HostLedFrame", { HostLedLevel = 777 }, 100)
  expect_signal(CH, 0x129, "DynEcho", z, 1000)
  expect_signal(CH, 0x12B, "DynLed", 777, 1000)
  s:stop()
  l:stop()
  local d = uds.open(CH, { tx = 0x7B0, rx = 0x7B8 })
  d:session(0x03)
  check.equal(tohex(d:raw("\x11\x01")), "51 01")
  sleep_ms(2500)
  drain()
  -- the new boot arms the 300 ms deadline at once, so with nothing sent since the CM4 holds
  -- timeout — never the command the window held before the reset
  for _ = 1, 10 do
    check.equal((value(0x129, "DynEcho", 1000)), TIMEOUT, "DynEcho after the reset, nothing sent since")
  end
  check.equal((value(0x12B, "DynLed", 1000)), 0, "DynLed right after the reset, nothing sent since")
  -- and the gate the new boot opened carries a new command
  s = commander(z)
  expect_signal(CH, 0x129, "DynEcho", z, 1000)
  s:stop()
end)
