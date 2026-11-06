-- @project diag_bench.blobnet
-- Bench helper, not a test of anything: the domain node's `ps` over its CAN shell (a raw frame on
-- 0x7F0 in, the ISO-TP answer on 0x7F1, flow control on 0x7F2), printed PS_N times (default 3) a
-- second apart — this core's busy and ISR shares over the last 1 s window, the CM4's busy share and
-- each thread's (docs/xcore.md, "Busy share"). Bench only, so not in CI.
local n = tonumber(os.getenv("PS_N") or "3")

test("ps", function()
  local tp = isotp.open("compute", { tx = 0x7F2, rx = 0x7F1 })
  for _ = 1, n do
    bus.send("compute", 0x7F0, "ps")
    print(tp:recv(1000) or "(no answer)")
    sleep_ms(1000)
  end
  tp:close()
end)
