#!/usr/bin/env bash
# On-target regression test for the generated SOME/IP image (docs/someip.md
# target + P3 routing rungs) — the eth twin of the io hwtest scripts.
#
# Runs against a live H735-DK on the LAN, probed FROM THE WINDOWS HOST via
# powershell.exe (WSL NAT delivers neither subnet broadcasts nor unsolicited
# inbound UDP — the bench recipe of emb#158): the probe binds the configured
# peer endpoint (30491), so the board's static-source filter accepts it.
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
# Exit: 0 = pass, 1 = FAILED, 2 = SKIP (no board/probe host). Flashing
# requires an explicit BLOB_H735_SERIAL (the H755 shares the bench).
#
# Usage: BLOB_H735_SERIAL=<serial> ./bench_test.sh [--flash]
set -uo pipefail
cd "$(dirname "$0")"
FLASH=0; [ "${1:-}" = "--flash" ] && FLASH=1

command -v powershell.exe >/dev/null 2>&1 || { echo "SKIP: no powershell.exe (not a WSL bench host)"; exit 2; }

if [ "$FLASH" = 1 ]; then
  [ -n "${BLOB_H735_SERIAL:-}" ] || { echo "SKIP: flash requested without BLOB_H735_SERIAL"; exit 2; }
  st-info --probe 2>/dev/null | grep -q "$BLOB_H735_SERIAL" || { echo "SKIP: probe $BLOB_H735_SERIAL not attached"; exit 2; }
  make >/dev/null || { echo "FAIL: build error"; exit 1; }
  make flash H735="$BLOB_H735_SERIAL" >/dev/null 2>&1 || { echo "FAIL: flash error"; exit 1; }
  sleep 6 # PHY link + NetX bring-up
fi

PS=$(mktemp --suffix=.ps1)
trap 'rm -f "$PS"' EXIT
cat > "$PS" <<'EOF'
$ErrorActionPreference = 'Stop'
try { $udp = New-Object System.Net.Sockets.UdpClient(30491) } catch { Write-Output 'SKIP: peer port busy'; exit }
$udp.Client.ReceiveTimeout = 2000
$board = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('192.168.0.50'), 30490)
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
    if ($d.Length -ge 16 -and $d[14] -eq $t) { return $d }
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
  if ($d.Length -ge 16 -and $d[2] -eq 0x80 -and $d[3] -eq 0x01) { $saw = $true; break }
}
if (-not $saw) { Write-Output 'FAIL: events stopped during rpc'; exit }
Write-Output 'PASS'
$udp.Close()
EOF
OUT=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$PS")" 2>&1 | tr -d '\r' | tail -1)
case "$OUT" in
  PASS) echo "PASS: rpc correlation + error + gate + wide response + live events"; exit 0 ;;
  SKIP*) echo "$OUT"; exit 2 ;;
  *) echo "${OUT:-FAIL: no probe output}"; exit 1 ;;
esac
