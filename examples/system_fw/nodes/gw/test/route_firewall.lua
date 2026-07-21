-- The DISSOLUTION frame route, end-to-end on two vcans. system.toml declares ONE
-- raw FRAME route (DiagFrame, compute -> edge); the full-contract compare proved
-- both buses define DiagFrame identically, so the gateway forwards the PDU UNCHANGED
-- (no decode/re-encode). It is also a FIREWALL: only the routed frame crosses.
-- CAN1 = vcan0 (compute), CAN2 = vcan1 (edge).
-- The running forwarder is the sanctioned transport (intra-thread in the one comm
-- loop, tx-ready gated, no queue) — REQ-TOPO-010.
-- @verifies REQ-TOPO-007, REQ-TOPO-009, REQ-TOPO-010

test("frame route: DiagFrame(0x400) forwards byte-for-byte compute -> edge", function()
  local pdu = fromhex("DE AD BE EF 11 22 33 44")
  local got = nil
  for _ = 1, 120 do
    bus.send("CAN1", 0x400, pdu)
    local f = bus.recv("CAN2", 20)
    if f and f.id == 0x400 then got = f.data; break end
  end
  check.truthy(got ~= nil, "0x400 (DiagFrame) appeared on the edge bus")
  check.equal(got, pdu) -- carried UNCHANGED (raw forward, no re-encode)
end)

test("firewall: PrivateFrame(0x401) is NOT routed, never reaches edge", function()
  -- drain the edge bus, then inject the private frame repeatedly and confirm it
  -- never crosses — only the frame named by a route is on the allow-list.
  while bus.recv("CAN2", 0) do end
  local priv = fromhex("01 02 03 04 05 06 07 08")
  local leaked = false
  for _ = 1, 40 do
    bus.send("CAN1", 0x401, priv)
    local f = bus.recv("CAN2", 5)
    while f do
      if f.id == 0x401 then leaked = true end
      f = bus.recv("CAN2", 0)
    end
  end
  check.truthy(not leaked, "PrivateFrame (0x401) must not cross the gateway")
end)
