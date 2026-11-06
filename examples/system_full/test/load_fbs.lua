-- @project diag_bench.blobnet
-- The domain node's load FBs (nodes/domain/ecu.toml, "Load FBs"), read off the compute bus: 20 FBs
-- on the CM7 and 10 on the CM4 pass a hop count from HostLedLevel along a chain that stays on one
-- core, goes down to the CM4 twice and comes back up three times. With HostLedLevel x, LoadOutA..E
-- (0x140..0x144) read x+13, x+10, x+17, x+20 and x+20 — A, C and D the values the CM7 read up from
-- the CM4. 0xFFFFFFFF on A, C or D means lanes that did not belong together, and on C and D also the
-- CM4's two paths disagreeing (SatLoadF), carried on unchanged. Each FB is a 10 ms handler, so a new
-- x reaches the last of them within a few dispatches of each hop.
-- Bench only (the flashed board on the CANsub), so not in CI; both banks flashed from one build, as
-- xcore_domain.lua says.

local CH = "compute"

local outs = {
  { id = 0x140, sig = "LoadOutA", hops = 13 },
  { id = 0x141, sig = "LoadOutB", hops = 10 },
  { id = 0x142, sig = "LoadOutC", hops = 17 },
  { id = 0x143, sig = "LoadOutD", hops = 20 },
  { id = 0x144, sig = "LoadOutE", hops = 20 },
}

test("load: every load output carries HostLedLevel plus its hop count", function()
  -- two values no earlier run left on the board: the chain must carry each one through
  local first = math.floor(now_ms()) % 900 + 1
  for _, x in ipairs({ first, (first + 450) % 900 + 1 }) do
    local s = bus.send_message_cyclic(CH, "HostLedFrame", { HostLedLevel = x }, 100)
    local ok, err = pcall(function()
      for _, o in ipairs(outs) do
        expect_signal(CH, o.id, o.sig, x + o.hops, 2000)
      end
    end)
    s:stop()
    if not ok then error(err, 0) end
  end
end)

test("load: the load outputs go out every 100 ms", function()
  local seen = {}
  local t0 = now_ms()
  while now_ms() - t0 < 2000 do
    local f = bus.recv(CH, 50)
    if f then seen[f.id] = (seen[f.id] or 0) + 1 end
  end
  for _, o in ipairs(outs) do
    check.between(seen[o.id] or 0, 18, 22, o.sig .. " frames in 2 s")
  end
end)
