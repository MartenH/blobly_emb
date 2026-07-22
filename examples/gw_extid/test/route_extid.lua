-- A raw-PDU gateway forwarding an EXTENDED-id (29-bit) frame: the driver Frame carries
-- an ext flag now, so the forward preserves the extended id (a standard-id forwarder
-- would truncate/mis-send it). CAN1 = vcan0 (inject), CAN2 = vcan1 (read).
-- @verifies REQ-TOPO-007

test("extended-id frame is raw-forwarded, staying extended", function()
  local pdu = fromhex("DE AD BE EF CA FE BA BE")
  local got = nil
  for _ = 1, 120 do
    bus.send("CAN1", 0x10FD0500, pdu, { ext = true }) -- opts.ext = extended (29-bit) id
    local f = bus.recv("CAN2", 20)
    -- require BOTH the id AND the extended flag on the dest — proving the ext format survived
    if f and f.id == 0x10FD0500 and f.ext then got = f.data; break end
  end
  check.truthy(got ~= nil, "the frame arrived on the dest bus AND is still extended")
  check.equal(got, pdu)
end)
