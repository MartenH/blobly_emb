#!/usr/bin/env python3
"""Minimal ISO 13400 DoIP tester for examples/h735_doip — bench aid.

Run from a host on the board's L2 segment (the Windows host, NOT a NAT'd WSL VM):
    python doip_client.py [board_ip]     # default 192.168.0.50

Does: routing activation, UDS 0x22 F190 (read identity), UDS 0x3E (tester present).
"""
import socket, struct, sys

BOARD = sys.argv[1] if len(sys.argv) > 1 else "192.168.0.50"
ENTITY, TESTER = 0x0E80, 0x0E00

def frame(ptype, payload):
    return struct.pack(">BBHI", 0x02, 0xFD, ptype, len(payload)) + payload

def read_exact(s, n):
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise RuntimeError("connection closed by board mid-message")
        data += chunk
    return data

def read_msg(s):
    hdr = read_exact(s, 8)
    _, _, ptype, plen = struct.unpack(">BBHI", hdr)
    return ptype, read_exact(s, plen)

def diag(s, uds_bytes):
    s.sendall(frame(0x8001, struct.pack(">HH", TESTER, ENTITY) + uds_bytes))
    pt, pl = read_msg(s)          # positive/neg ack
    assert pt == 0x8002, f"expected diag ack, got 0x{pt:04X} nack=0x{pl[4]:02X}"
    pt, pl = read_msg(s)          # UDS response
    assert pt == 0x8001
    return pl[4:]

s = socket.create_connection((BOARD, 13400), timeout=5)
s.sendall(frame(0x0005, struct.pack(">HBI", TESTER, 0x00, 0)))
pt, pl = read_msg(s)
assert pt == 0x0006 and pl[4] == 0x10, f"routing activation failed (0x{pl[4]:02X})"
print(f"[ok] routing activation -> entity 0x{ENTITY:04X}")

r = diag(s, bytes([0x22, 0xF1, 0x90]))
assert r[0] == 0x62, f"0x22 negative: {r.hex()}"
print(f"[ok] 0x22 F190 read -> '{r[3:].decode(errors='replace')}'")

r = diag(s, bytes([0x3E, 0x00]))
assert r[0] == 0x7E, f"0x3E negative: {r.hex()}"
print("[ok] 0x3E tester present")
print("\nDoIP bench: ALL PASS")
s.close()
