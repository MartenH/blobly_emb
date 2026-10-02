-- @project doip_bench.blobnet
-- sysnode under the network load netload_bench.sh offers (#349), for 30 s: whether its DoIP server
-- stays reachable — the connection opened (retried each CpuLoad frame until it does) and DID 0xF190
-- read once per CpuLoad frame — and the FB threads' load (CpuLoad, 0x7E0 on compute: byte 1 is the
-- Loom's percent over the last second, every 500 ms; the IP thread's own work is not in it).
-- netload_bench.sh runs it beside each phase and judges the `doip:` line; this fails only when the
-- node stops sending CpuLoad.
local secs = 30

test("sysnode's DoIP reachability and FB load under network load", function()
  local d = nil
  local open_failed, lo, hi, sum, answered, asked, samples = 0, 101, -1, 0, 0, 0, 0
  local stop = os.time() + secs
  while os.time() < stop do
    samples = samples + 1
    local f = expect("compute", 0x7E0, 2000)
    local pct = string.byte(f.data, 1)
    lo = math.min(lo, pct)
    hi = math.max(hi, pct)
    sum = sum + pct
    if d == nil then
      local ok, c = pcall(uds.open, "sysnode")
      if ok then d = c else open_failed = open_failed + 1 end
    end
    if d ~= nil then
      asked = asked + 1
      if pcall(function() return d:read_did(0xF190) end) then
        answered = answered + 1
      end
    end
  end
  print(string.format("fbload: min %d%% mean %.1f%% max %d%% over %d samples", lo, sum / samples, hi, samples))
  print(string.format("doip: opened %s after %d failed opens; answered %d asked %d samples %d",
    d ~= nil and "yes" or "no", open_failed, answered, asked, samples))
end)
