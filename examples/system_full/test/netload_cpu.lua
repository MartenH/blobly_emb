-- @project doip_bench.blobnet
-- sysnode under the network load netload_bench.sh offers (#349): the node's own CPU load (CpuLoad,
-- 0x7E0 on compute — byte 1 is core 0's percent over the last second, every 500 ms) and whether
-- its DoIP server still answers, once per CpuLoad frame for 30 s. netload_bench.sh runs it beside
-- each phase; it reports, and fails only when the node stops sending CpuLoad.
local secs = 30

test("sysnode's CPU load and DoIP under network load", function()
  local d = uds.open("sysnode")
  local lo, hi, sum, answered, samples = 101, -1, 0, 0, 0
  local stop = os.time() + secs
  while os.time() < stop do
    samples = samples + 1
    local f = expect("compute", 0x7E0, 2000)
    local pct = string.byte(f.data, 1)
    lo = math.min(lo, pct)
    hi = math.max(hi, pct)
    sum = sum + pct
    if pcall(function() return d:read_did(0xF190) end) then
      answered = answered + 1
    end
  end
  print(string.format("cpuload: min %d%% mean %.1f%% max %d%% over %d samples; DoIP answered %d/%d",
    lo, sum / samples, hi, samples, answered, samples))
end)
