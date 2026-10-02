#!/usr/bin/env python3
"""sysnode's DoIP entity at the ISO 13400-2 transport level, on the bench (docs/net.md, "The entity
at the transport level"): entity status and power mode over UDP and TCP, the alive check, the
routing-activation policy sysnode is generated with (`testers = [0x0E00]`, activation type 0x00)
and its refusals closing the socket, and T_TCP_Initial_Inactivity. Raw sockets, stdlib only —
blobly_net's tester has no call for these payload types.

    python3 examples/system_full/test/doip_entity.py [host]     # default 192.168.0.50

Exit 0 = pass, 1 = a check failed, 2 = the entity is not reachable (SKIP).
"""
import socket
import struct
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.0.50"
PORT = 13400
ENTITY = 0x07A0
TESTER = 0x0E00  # the one tester sysnode admits
fails = 0


def msg(ptype, payload=b""):
    return struct.pack(">BBHI", 0x02, 0xFD, ptype, len(payload)) + payload


def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  " + detail))
    if not ok:
        fails += 1


def udp(req):
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.settimeout(2)
    try:
        u.sendto(req, (HOST, PORT))
        data, _ = u.recvfrom(256)
        return data
    finally:
        u.close()


def read_msg(s):
    hdr = b""
    while len(hdr) < 8:
        c = s.recv(8 - len(hdr))
        if not c:
            return None
        hdr += c
    _, _, ptype, n = struct.unpack(">BBHI", hdr)
    body = b""
    while len(body) < n:
        c = s.recv(n - len(body))
        if not c:
            return None
        body += c
    return ptype, body


def tcp():
    s = socket.create_connection((HOST, PORT), timeout=3)
    s.settimeout(3)
    return s


def activation(sa, atype=0x00):
    return msg(0x0005, struct.pack(">HB", sa, atype) + b"\0\0\0\0")


def closed_by_entity(s, within):
    # a FIN reads as b"", a reset (NetX unaccepting before our FIN) as an error: both are a close
    s.settimeout(within)
    try:
        return s.recv(64) == b""
    except socket.timeout:
        return False
    except (ConnectionResetError, BrokenPipeError):
        return True


def status_ok(r, open_):
    return r is not None and r[0] == 0x4002 and r[1] == bytes([0x01, 1, open_, 0, 0, 0, 248])


try:
    st = udp(msg(0x4001))
except OSError as e:
    print("SKIP: no DoIP entity at %s (%s)" % (HOST, e))
    sys.exit(2)

# UDP: entity status (no tester connected) and power mode
check("udp entity status: node, 1 socket max, 0 open, 248 bytes",
      st[2:4] == b"\x40\x02" and st[8:] == bytes([0x01, 1, 0, 0, 0, 0, 248]), st.hex())
pm = udp(msg(0x4003))
check("udp power mode: ready", pm[2:4] == b"\x40\x04" and pm[8:] == b"\x01", pm.hex())

# a tester address not in sysnode's list: 0x00 unknown source, and the socket closes
s = tcp()
s.sendall(activation(0x0E01))
r = read_msg(s)
check("unlisted tester refused 0x00", r is not None and r[0] == 0x0006 and r[1][4] == 0x00, repr(r))
check("... and the entity closes the socket", closed_by_entity(s, 3))
s.close()

# an activation type it does not serve: 0x06, and the socket closes
s = tcp()
s.sendall(activation(TESTER, 0x01))
r = read_msg(s)
check("WWH-OBD activation refused 0x06", r is not None and r[0] == 0x0006 and r[1][4] == 0x06, repr(r))
check("... and the entity closes the socket", closed_by_entity(s, 3))
s.close()

# an invalid payload length: generic NACK 0x04, and the socket closes
s = tcp()
s.sendall(msg(0x4001, b"\0"))
r = read_msg(s)
check("invalid length NACKed 0x04", r == (0x0000, b"\x04"), repr(r))
check("... and the entity closes the socket", closed_by_entity(s, 3))
s.close()

# the bench tester: activated; then the info requests over TCP, the alive check both ways
s = tcp()
s.sendall(activation(TESTER))
r = read_msg(s)
check("bench tester activated 0x10", r is not None and r[0] == 0x0006 and r[1][4] == 0x10, repr(r))
s.sendall(msg(0x4001))
check("tcp entity status: 1 open", status_ok(read_msg(s), 1))
check("udp entity status while connected: 1 open", udp(msg(0x4001))[8:] == bytes([0x01, 1, 1, 0, 0, 0, 248]))
s.sendall(msg(0x4003))
r = read_msg(s)
check("tcp power mode: ready", r == (0x4004, b"\x01"), repr(r))
s.sendall(msg(0x0007))
r = read_msg(s)
check("alive check request answered with the entity address", r == (0x0008, struct.pack(">H", ENTITY)), repr(r))
# an alive check response gets no reply: the next answer is the tester present's
s.sendall(msg(0x0008, struct.pack(">H", TESTER)))
s.sendall(msg(0x8001, struct.pack(">HH", TESTER, ENTITY) + b"\x3E\x00"))
r = read_msg(s)
check("alive check response unanswered (next is the diag ack)", r is not None and r[0] == 0x8002, repr(r))
r = read_msg(s)
check("... then the tester present answer", r is not None and r[0] == 0x8001 and r[1][4:] == b"\x7E\x00", repr(r))
s.sendall(activation(TESTER))
r = read_msg(s)
check("the registered tester activates again 0x10", r is not None and r[1][4] == 0x10, repr(r))
s.close()
time.sleep(0.5)

# T_TCP_Initial_Inactivity (2 s from accept): a connection that never activates is closed
s = tcp()
t0 = time.monotonic()
closed = closed_by_entity(s, 5)
dt = time.monotonic() - t0
check("an idle unactivated connection is closed at ~2 s", closed and 1.5 <= dt <= 3.0, "closed=%s after %.2f s" % (closed, dt))
s.close()

print("doip_entity: %d failed" % fails)
sys.exit(1 if fails else 0)
