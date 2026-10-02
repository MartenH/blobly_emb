#!/usr/bin/env bash
# sysnode under a UDP flood (#349): does the NetX IP thread — above the FBs on an image with an eth
# thread, past a per-tick receive budget demoted below them (driver/eth/net_rx_budget.h) — keep the
# node working and reachable? Two 30 s phases, idle then flood, each measuring:
#
#   GwStatus (0x8020, cyclic 1 s): every event the eth thread sends, and GwUptime.seconds, which the
#     GwHealth FB counts once a second — an FB starved by the network stops it advancing while the
#     eth thread keeps sending. Captured on the Windows host (powershell.exe, bound to the bench
#     tester's port 30491: WSL NAT does not deliver unsolicited inbound UDP).
#   ping RTT and loss (PING.EXE from the Windows host, one a second): the IP thread's own latency.
#   DoIP reachability (netload_cpu.lua through blobly_net — BLOBLY_NET, and a CANsub on compute as
#     doip_bench.blobnet names it): whether the connection opens and how many reads it answers, plus
#     the FB threads' load from CpuLoad.
#
# The flood is UDP from WSL to the node's SOME/IP port (30490) as fast as python can send — through
# the IP thread into the eth thread's socket, which drops what is not its peer's. Its offered rate
# is printed; the board's side is nx_driver_rx_demoted (ticks the IP thread demoted itself), read
# over SWD with openocd (`mdw` at the symbol's address; st-util resets the target).
#
# Exit: 0 = through the flood every GwStatus came, the FB counted each second, and DoIP stayed
# reachable (the connection opened and answered at least DOIP_MIN_PCT of the reads — main's design,
# the IP thread always below the FBs, answered 86% on the bench); 1 = one of those did not hold;
# 2 = SKIP (no powershell.exe, no BLOBLY_NET, or no GwStatus while idle — sysnode not on the LAN).
#
# Usage: ./netload_bench.sh            (BLOB_SYSNODE_IP, default 192.168.0.50)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
IP="${BLOB_SYSNODE_IP:-192.168.0.50}"
SECS=30
DOIP_MIN_PCT=70

command -v powershell.exe >/dev/null 2>&1 || { echo "SKIP: no powershell.exe (not a WSL bench host)"; exit 2; }
[ -n "${BLOBLY_NET:-}" ] || { echo "SKIP: BLOBLY_NET unset (DoIP reachability is measured through blobly_net)"; exit 2; }
PING=/mnt/c/Windows/System32/PING.EXE

PS=$(mktemp --suffix=.ps1)
trap 'rm -f "$PS"' EXIT
cat > "$PS" <<'EOF'
param([string]$BoardIp = '192.168.0.50', [int]$Secs = 30)
$ErrorActionPreference = 'Stop'
try { $udp = New-Object System.Net.Sockets.UdpClient(30491) } catch { Write-Output 'SKIP: peer port busy'; exit }
$udp.Client.ReceiveTimeout = 200
$board = [System.Net.IPAddress]::Parse($BoardIp)
$src = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$at = @(); $up = @()
while ($sw.ElapsedMilliseconds -lt $Secs * 1000) {
  try { $d = $udp.Receive([ref]$src) } catch { continue }
  $t = $sw.ElapsedMilliseconds
  # GwStatus: event 0x8020 from the board, GwUptime.seconds the payload's u32 (little-endian)
  if ($src.Address.Equals($board) -and $d.Length -ge 20 -and $d[2] -eq 0x80 -and $d[3] -eq 0x20) {
    $at += $t
    $up += [System.BitConverter]::ToUInt32($d, 16)
  }
}
$n = $at.Count
if ($n -lt 2) { Write-Output "events $n"; exit }
$gaps = @(); for ($i = 1; $i -lt $n; $i++) { $gaps += $at[$i] - $at[$i - 1] }
$m = $gaps | Measure-Object -Minimum -Maximum -Average
Write-Output ("events {0} gap_min {1} gap_mean {2:F0} gap_max {3} uptime_advanced {4}" -f $n, $m.Minimum, $m.Average, $m.Maximum, ($up[$n - 1] - $up[0]))
EOF
WPS=$(wslpath -w "$PS")

# blobly_net's script runner, built once so a phase's CpuLoad sampling starts with the phase
RUNNER=$(mktemp -u)
(cd "$BLOBLY_NET" && v -enable-globals -path "@vlib|@vmodules|modules" -o "$RUNNER" cmd/script/run.v) ||
  { echo "FAIL: cannot build blobly_net's script runner"; exit 1; }
trap 'rm -f "$PS" "$RUNNER"' EXIT

# one phase: GwStatus + ping + DoIP/CpuLoad for SECS, with or without the flood beside it
phase() {
  local name=$1 flood=$2 out
  out=$(mktemp -d)
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WPS" -BoardIp "$IP" -Secs "$SECS" >"$out/gw" 2>&1 &
  local gw=$!
  "$PING" -n "$SECS" "$IP" >"$out/ping" 2>&1 &
  local pg=$!
  "$RUNNER" "$here/netload_cpu.lua" >"$out/cpu" 2>&1 &
  local lua=$!
  if [ "$flood" = 1 ]; then
    python3 - "$IP" "$SECS" >"$out/flood" 2>&1 <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
dst, secs = (sys.argv[1], 30490), float(sys.argv[2])
p = bytes(18)  # a minimum-size Ethernet frame
n, end = 0, time.monotonic() + secs
while time.monotonic() < end:
    for _ in range(256):
        try:
            s.sendto(p, dst)
            n += 1
        except OSError:
            pass
print(f"flood: {n} datagrams in {secs:.0f} s, {n / secs:.0f}/s offered")
PY
  fi
  wait $gw $pg $lua
  echo "== $name"
  [ "$flood" = 1 ] && cat "$out/flood"
  cat "$out/gw" | tr -d '\r'
  tr -d '\r' <"$out/ping" | grep -E "Lost|Average" | sed 's/^ */ping: /'
  DOIP=$(grep -E "^doip:" "$out/cpu")
  grep -E "^(fbload|doip):" "$out/cpu" || { echo "doip: no report — the script failed:"; tail -5 "$out/cpu"; }
  GW=$(tr -d '\r' <"$out/gw")
  rm -rf "$out"
}

field() { echo "$GW" | sed -n "s/.*$1 \([0-9]*\).*/\1/p"; }
dfield() { echo "$DOIP" | sed -n "s/.*$1 \([0-9a-z]*\).*/\1/p"; }

phase idle 0
case "$GW" in SKIP*) exit 2 ;; esac
[ "$(field events)" -ge 2 ] 2>/dev/null || { echo "SKIP: no GwStatus from $IP while idle"; exit 2; }
phase flood 1
ev=$(field events); adv=$(field uptime_advanced); gmax=$(field gap_max)
opened=$(dfield opened); ans=$(dfield answered); n=$(dfield samples)
fail=0
# every second's event, each one a second further on the FB's count, none a second late
if ! { [ "${ev:-0}" -ge $((SECS - 2)) ] && [ "${adv:-0}" -ge $((ev - 2)) ] && [ "${gmax:-99999}" -lt 2000 ]; }; then
  echo "FAIL: under the flood GwStatus came ${ev:-0}x in ${SECS} s, the FB advanced ${adv:-0}, the longest gap ${gmax:-?} ms"
  fail=1
fi
# reachable: the tester's connection opened, and most reads were answered
if [ "$opened" != yes ] || [ $((${ans:-0} * 100)) -lt $((DOIP_MIN_PCT * ${n:-1})) ]; then
  echo "FAIL: DoIP unreachable under the flood — opened ${opened:-unknown}, answered ${ans:-0} of ${n:-?} (need ${DOIP_MIN_PCT}%)"
  fail=1
fi
[ "$fail" = 0 ] && echo "PASS: GwStatus kept its cadence, the FB its count, and DoIP stayed reachable through the flood"
exit $fail
