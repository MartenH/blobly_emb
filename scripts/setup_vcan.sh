#!/usr/bin/env bash
# Bring up the virtual CAN interfaces for host/sim builds (vcan0, and vcan1 for
# multi-bus examples like `gateway`).
set -euo pipefail

sudo modprobe vcan
for dev in vcan0 vcan1; do
  sudo ip link add dev "$dev" type vcan 2>/dev/null || true
  sudo ip link set up "$dev"
done

echo "vcan0, vcan1 are up."
echo "  watch traffic:  candump vcan0   (or vcan1)"
echo "  inject speed :  cansend vcan0 100#000003E8   # classic, VehicleSpeed=100 km/h"
echo "  expect lamp  :  110#01  when kph > 120"
