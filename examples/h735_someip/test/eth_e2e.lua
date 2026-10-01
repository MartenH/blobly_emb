-- Bench suite for the H735's SOME/IP receive path (REQ-E2E-002 on eth, emb #299), driven by
-- blobly_net over the LAN — the board at 192.168.0.50, this host at its configured peer
-- 192.168.0.190:30491 (the board accepts and answers only that endpoint):
--
--   <blobly_net>/cmd/script runner  examples/h735_someip/test/eth_e2e.lua
--
-- Give the board ~15 s after a flash or reset: NetX and the PHY link come up first, and a run
-- before that hears nothing at all.
--
-- emb #299 on silicon: the H735's SOME/IP receive path reports E2E's verdict (REQ-E2E-002).
-- BenchCmdSafe 0x8011: level@0, counter@1, CRC@2, Data ID 0x22, P01, 500 ms timeout.
-- BenchSafeStatus 0x8005 carries back { level@0, lost@1 (u16 LE), status@3 }: status 1 ok,
-- 2 timeout, 3 integrity; lost = the frames the E2E sequence showed missing.
local to = "192.168.0.50:30490"
local ctr = 0
local function safe(level, corrupt, skip)
  ctr = (ctr + 1 + (skip or 0)) % 15
  local f = e2e.p01_protect(string.char(level, 0, 0), 0x22, 2, 1, ctr)
  if corrupt then f = f:sub(1, 2) .. string.char(string.byte(f, 3) ~ 0xFF) end
  return { service = 0x0100, method = 0x8011, payload = f }
end
-- the newest BenchSafeStatus heard so far: an event-mode frame is sent only on CHANGE, so a
-- window after an unchanged status hears nothing new
local cur_lvl, cur_st, cur_lost
local function note(heard)
  for _, m in ipairs(heard) do
    if m.method == 0x8005 then
      cur_lvl, cur_st = string.byte(m.payload, 1), string.byte(m.payload, 4)
      cur_lost = string.byte(m.payload, 2) + 256 * string.byte(m.payload, 3)
    end
  end
end
local function status_after(msgs, window)
  if msgs then
    note(someip.send(to, msgs, { window_ms = window }))
  else
    note(someip.listen(window, { port = 30491 })) -- silence: send nothing, just hear
  end
  return cur_lvl, cur_st
end

test("a protected command reads ok", function()
  local lvl, st
  for _ = 1, 5 do lvl, st = status_after(safe(42), 150) end
  check.equal(st, 1, "status"); check.equal(lvl, 42, "level")
end)

test("a silent sender reads timeout, its value withheld", function()
  local lvl, st = status_after(nil, 900) -- nothing sent for 900 ms > the 500 ms timeout
  check.equal(st, 2, "status"); check.equal(lvl, 0, "the stale level was withheld")
end)

test("a corrupt frame reads integrity, and a good one ok again", function()
  local _, st = status_after(safe(42, true), 300)
  check.equal(st, 3, "status after a corrupt frame")
  local lvl, st2 = status_after(safe(77), 300)
  check.equal(st2, 1, "status after a good frame"); check.equal(lvl, 77)
end)

test("a counter gap is reported as lost frames, the value still ok", function()
  status_after(safe(50), 300)
  local before = cur_lost
  local lvl, st = status_after(safe(51, false, 3), 300) -- three frames missing from the sequence
  check.equal(st, 1, "a lost frame is usable"); check.equal(lvl, 51)
  check.equal(cur_lost - before, 3, "lost frames counted")
end)
