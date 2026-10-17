#!/usr/bin/env bash
# On-target regression test for tcu, system_full's SOME/IP node (docs/someip.md target + P3
# routing rungs) on the NUCLEO-H723 at tcu's address (TCU_ADDR, ../../test/net_env.sh) — the eth
# twin of the io hwtest scripts.
#
# Probed FROM THE WINDOWS HOST via powershell.exe (WSL NAT delivers neither subnet broadcasts nor
# unsolicited inbound UDP — the bench recipe of emb#158): the probe binds the bench tester's
# endpoint port (30491, tcu's peer in system.toml), so the board's static-source filter accepts it,
# and it sends before it listens.
#
#   RPC (REQ-NET-016): a request to the shell method answers with a RESPONSE
#     whose Request ID (client+session) is mirrored VERBATIM, message type
#     0x80, return code ok, and a live payload (`uptime` text); an unknown
#     method id answers a distinguishable ERROR (0x81, rc_unknown_method) —
#     attributable, never a silent drop; a dead-session request IS silently
#     dropped (the envelope gate, not the router); `help` returns a >64-byte
#     response (the max_rpc wide-response path, one datagram).
#   Events keep streaming around the RPC traffic (BenchTelem 0x8001 observed).
#
# @verifies REQ-NET-016
#
# The E2E-protected receive path on the same node is ../../test/tcu_e2e.lua (blobly_net).
#
# The probe targets BLOB_SOMEIP_IP (default TCU_ADDR = tcu, gen-net.env). Any node offering the same
# service and shell method answers the same legs at its own address, read-only.
#
# Exit: 0 = pass, 1 = FAILED, 2 = SKIP (no board/probe host). Flashing requires an explicit
# BLOB_TCU_SERIAL — a TCU-specific variable, not a chip one: an H723 and an H735 report the same
# chip id, and the bench H723 is usually zone_a's board, so `make hwtest` (which passes --flash
# to every script) must not replace zone_a with tcu unless the bench asked for a tcu.
# Every received datagram is filtered by source == the board's address: sysnode sends its
# GwStatus to the same tester port.
#
# Usage: BLOB_TCU_SERIAL=<serial> ./bench_test.sh [--flash]
set -uo pipefail
cd "$(dirname "$0")"
FLASH=0; [ "${1:-}" = "--flash" ] && FLASH=1
command -v powershell.exe >/dev/null 2>&1 || { echo "SKIP: no powershell.exe (not a WSL bench host)"; exit 2; }

if [ "$FLASH" = 1 ]; then
  # --flash builds and writes tcu's image and probes it there. Flashing it while probing another
  # node's address would report on an image this script never wrote.
  [ -z "${BLOB_SOMEIP_IP:-}" ] || { echo "SKIP: --flash builds and probes tcu, not the node at $BLOB_SOMEIP_IP"; exit 2; }
  [ -n "${BLOB_TCU_SERIAL:-}" ] || { echo "SKIP: flash requested without BLOB_TCU_SERIAL (the H723 that runs tcu)"; exit 2; }
  st-info --probe 2>/dev/null | grep -q "$BLOB_TCU_SERIAL" || { echo "SKIP: probe $BLOB_TCU_SERIAL not attached"; exit 2; }
  make >/dev/null || { echo "FAIL: build error"; exit 1; }
  make flash SERIAL="$BLOB_TCU_SERIAL" >/dev/null 2>&1 || { echo "FAIL: flash error"; exit 1; }
  sleep 6 # PHY link + NetX bring-up
fi

# tcu as the system was last generated (the build above regenerates it), unless a target is named;
# a named node offers the same service on the same ports
if [ -n "${BLOB_SOMEIP_IP:-}" ]; then
  BOARD_IP=$BLOB_SOMEIP_IP
  [ -f ../../gen-net.env ] && . ../../test/net_env.sh
else
  . ../../test/net_env.sh
  BOARD_IP=$TCU_ADDR
fi
PEER_PORT=${TESTER_PORT:-30491}
BOARD_PORT=${TCU_PORT:-30490}

PS=$(mktemp --suffix=.ps1)
trap 'rm -f "$PS"' EXIT
cat > "$PS" <<'EOF'
param([Parameter(Mandatory)][string]$BoardIp, [Parameter(Mandatory)][int]$PeerPort, [Parameter(Mandatory)][int]$BoardPort)
$ErrorActionPreference = 'Stop'
try { $udp = New-Object System.Net.Sockets.UdpClient($PeerPort) } catch { Write-Output 'SKIP: peer port busy'; exit }
$udp.Client.ReceiveTimeout = 2000
$boardAddr = [System.Net.IPAddress]::Parse($BoardIp)
$board = New-Object System.Net.IPEndPoint($boardAddr, $BoardPort)
$txt = [System.Text.Encoding]::ASCII
function Req([byte[]]$mid, [byte[]]$rid, [byte[]]$p) {
  $len = 8 + $p.Length
  return [byte[]](0x01,0x00) + $mid + [byte[]](0,0, ($len -shr 8), ($len -band 0xFF)) + $rid + [byte[]](0x01,0x01,0x00,0x00) + $p
}
function RecvType([int]$t) {
  $src = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
  $deadline = (Get-Date).AddSeconds(3)
  while ((Get-Date) -lt $deadline) {
    try { $d = $udp.Receive([ref]$src) } catch { continue }
    if ($src.Address.Equals($boardAddr) -and $d.Length -ge 16 -and $d[14] -eq $t) { return $d }
  }
  return $null
}
# warm the path (first datagram may race link-layer ARP)
$d = Req ([byte[]](0x00,0x01)) ([byte[]](0x0E,0x01,0x00,0x01)) ($txt.GetBytes('uptime'))
[void]$udp.Send($d, $d.Length, $board); [void](RecvType 0x80)
# leg 1: correlated response
$rid = [byte[]](0x0E,0x01,0x00,0x0B)
$d = Req ([byte[]](0x00,0x01)) $rid ($txt.GetBytes('uptime'))
[void]$udp.Send($d, $d.Length, $board)
$r = RecvType 0x80
if (-not $r) { Write-Output 'FAIL: no response to uptime'; exit }
if ($r[8] -ne 0x0E -or $r[9] -ne 0x01 -or $r[10] -ne 0x00 -or $r[11] -ne 0x0B) { Write-Output 'FAIL: Request ID not mirrored'; exit }
if ($r[15] -ne 0) { Write-Output 'FAIL: response rc not ok'; exit }
if (-not $txt.GetString($r[16..($r.Length-1)]).StartsWith('up ')) { Write-Output 'FAIL: uptime payload'; exit }
# leg 2: unknown method -> distinguishable error
$d = Req ([byte[]](0x00,0x02)) ([byte[]](0x0E,0x01,0x00,0x0C)) ($txt.GetBytes('x'))
[void]$udp.Send($d, $d.Length, $board)
$r = RecvType 0x81
if (-not $r) { Write-Output 'FAIL: no error for unknown method'; exit }
if ($r[15] -ne 0x03) { Write-Output 'FAIL: error rc not rc_unknown_method'; exit }
if ($r[2] -ne 0x00 -or $r[3] -ne 0x02) { Write-Output 'FAIL: error method not mirrored'; exit }
if ($r[8] -ne 0x0E -or $r[9] -ne 0x01 -or $r[10] -ne 0x00 -or $r[11] -ne 0x0C) { Write-Output 'FAIL: error Request ID not mirrored'; exit }
# leg 3: dead session -> silent drop
$d = Req ([byte[]](0x00,0x01)) ([byte[]](0x0E,0x01,0x00,0x00)) ($txt.GetBytes('uptime'))
[void]$udp.Send($d, $d.Length, $board)
if (RecvType 0x80) { Write-Output 'FAIL: dead-session request answered'; exit }
# leg 4: the wide response (>64B) rides one datagram
$d = Req ([byte[]](0x00,0x01)) ([byte[]](0x0E,0x01,0x00,0x0D)) ($txt.GetBytes('help'))
[void]$udp.Send($d, $d.Length, $board)
$r = RecvType 0x80
if (-not $r -or $r.Length -le 80) { Write-Output 'FAIL: wide help response missing/small'; exit }
# events still streaming around the rpc traffic
$src = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
$saw = $false
$deadline = (Get-Date).AddSeconds(2)
while ((Get-Date) -lt $deadline) {
  try { $d = $udp.Receive([ref]$src) } catch { continue }
  if ($src.Address.Equals($boardAddr) -and $d.Length -ge 16 -and $d[2] -eq 0x80 -and $d[3] -eq 0x01) { $saw = $true; break }
}
if (-not $saw) { Write-Output 'FAIL: events stopped during rpc'; exit }
Write-Output 'PASS'
$udp.Close()
EOF
OUT=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$PS")" -BoardIp "$BOARD_IP" -PeerPort "$PEER_PORT" -BoardPort "$BOARD_PORT" 2>&1 | tr -d '\r' | tail -1)
case "$OUT" in
  PASS) echo "PASS ($BOARD_IP): rpc correlation + error + gate + wide response + live events"; exit 0 ;;
  SKIP*) echo "$OUT"; exit 2 ;;
  *) echo "${OUT:-FAIL: no probe output}"; exit 1 ;;
esac
