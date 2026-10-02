#!/bin/sh
# The sysnode DoIP bench (doip_sysnode.lua) as a verification check: needs the H735 running
# sysnode on the LAN, the CANsub on compute, and blobly_net beside this repo (or BLOBLY_NET).
set -e
here=$(cd "$(dirname "$0")" && pwd)
net=${BLOBLY_NET:-$here/../../../../blobly_net}
[ -d "$net/modules" ] || { echo "doip_bench: no blobly_net at $net (set BLOBLY_NET)"; exit 2; }
cd "$net"
exec v -enable-globals -path "@vlib|@vmodules|modules" run cmd/script/run.v "$here/doip_sysnode.lua"
