# gw_extid — raw-forward an EXTENDED-id (29-bit) frame

A raw-PDU gateway that forwards an **extended-id** frame unchanged. The driver
`Frame` now carries an `ext` flag (and the `can_port.h` send/recv ABI a format-flags
word), so a raw forward preserves the 29-bit identifier — a standard-id-only forwarder
would truncate or mis-send it.

```sh
sudo make vcan
make -C examples/gw_extid
./examples/gw_extid/bin/app vcan0 vcan1 &
cansend vcan0 10FD0500#DEADBEEFCAFEBABE   # an EXTENDED id (8 hex digits)
candump vcan1                             # -> 10FD0500 [8] DE AD ...  (still 8 hex = extended)
```

Test (`test/route_extid.lua`) sends `{ ext = true }` and asserts the frame arrives on
the destination **and is still extended** (`f.ext`), proving the format survives the
forward. The same `ext` support is implemented on the STM32 H7 **FDCAN** backend
(XTD bit on TX, extended-accept in the RX filter) and the ST-HAL backend.

## Scope

Extended-id is supported for **raw frame routes** (both buses must agree on the id
width — a std↔ext mismatch needs a signal route). **CAN-FD** payloads (dlc > 8) and
signal-route ext destinations are a later increment. RTR frames are dropped (obsolete;
absent in CAN-FD).
