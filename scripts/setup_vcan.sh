#!/usr/bin/env bash
# Bring up the virtual CAN interfaces for host/sim builds. vcan0..vcan7 so
# multi-bus examples (gateway: 2, scale: 8) work; single-bus examples use vcan0.
set -euo pipefail

N="${VCAN_COUNT:-8}"

sudo modprobe vcan
for b in $(seq 0 $((N - 1))); do
	sudo ip link add dev "vcan$b" type vcan 2>/dev/null || true
	sudo ip link set up "vcan$b"
done

echo "vcan0..vcan$((N - 1)) are up."
echo "  watch traffic:  candump vcan0"
echo "  inject speed :  cansend vcan0 100#000003E8   # classic, VehicleSpeed=100 km/h"
echo "  expect lamp  :  110#01  when kph > 120"
