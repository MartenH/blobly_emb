#!/usr/bin/env bash
# Bring up a virtual CAN interface for the host/sim build.
set -euo pipefail

sudo modprobe vcan
sudo ip link add dev vcan0 type vcan 2>/dev/null || true
sudo ip link set up vcan0

echo "vcan0 is up."
echo "  watch traffic:  candump vcan0"
echo "  inject speed :  cansend vcan0 100##0.3412   # CAN-FD, kph=0x1234 (LE)"
echo "  expect lamp  :  101#01  when kph > 120"
