#!/usr/bin/env bash
# On-target regression test for P3c-0: the bare-metal superloop as the single-core trace runner
# (docs/trace-multicore.md §5.0) — examples/h735_app on the STM32H735G-DK, over SWD only.
#
# No CAN adapter and no host command: the generated superloop ARMS the ring at boot, and the
# Governor ramps Load past its 500 us budget within the first second, so the overrun trigger
# freezes the ring by itself. This script reads that frozen window straight out of RAM
# (g_trace_ring, 64 in-RAM trace.Record) and asserts what only a working runner produces:
#
#   1. the right board: g_cpu_mhz = 550 (an H723 on this image locks at 64 — bench notes)
#   2. the ring holds FB records, every id one the trace manifest names
#   3. the ring is FROZEN — identical across reads while Load keeps running every 1 ms — with
#      no command sent, so it armed itself at boot and something stopped it on target
#   4. at least one record carries flag_overran — the thing that stopped it was the trigger
#
# Durations are REPORTED, not bounded: the trip time and the overrunning duration depend on the
# Governor's ramp and the core's timing, and a bound on either is a check that can fail a
# healthy board (the lesson of examples/system_full/nodes/domain/bench_test.sh).
#
# The protocol half (TraceCmd stop/dump over ISO-TP) needs a CAN host and is not driven here;
# requirements/verifications.toml h735-app-baremetal-trace records that bench run.
#
# Exit: 0 = pass, 1 = FAILED (regression) or tooling missing, 2 = SKIP (no serial / board, or a
# read-only run against a board that is not running this image).
#
# Usage: BLOB_H735_SERIAL=<serial> ./bench_test.sh [--flash]
#   The serial is required even read-only: an H735 and an H723 report the same chip id, and
#   --flash overwrites whatever the board holds (on the system_full bench: sysnode's image —
#   reflash it from examples/system_full/nodes/sysnode afterwards).
set -uo pipefail
cd "$(dirname "$0")"
ELF=build/app.elf
BIN=build/app.bin
MAN=gen/trace-manifest.csv
FLASH=0; [ "${1:-}" = "--flash" ] && FLASH=1

for t in st-info st-flash arm-none-eabi-nm od cmp; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: $t not found — bench tooling missing (infrastructure)"; exit 1; }
done
[ -n "${BLOB_H735_SERIAL:-}" ] || { echo "SKIP: BLOB_H735_SERIAL not set (an H735 and an H723 look alike to st-info)"; exit 2; }
SERIAL=$BLOB_H735_SERIAL
PROBE=$(st-info --probe 2>&1) || { echo "FAIL: st-info --probe failed (infrastructure)"; exit 1; }
grep -q "$SERIAL" <<<"$PROBE" || { echo "SKIP: ST-LINK $SERIAL not attached — on-target test not run"; exit 2; }

if [ "$FLASH" = 1 ]; then
  echo "building + flashing h735_app ..."
  make all >/dev/null 2>&1 || { echo "FAIL: build error"; exit 1; }
  st-flash --serial "$SERIAL" write "$BIN" 0x08000000 >/dev/null 2>&1 || { echo "FAIL: flash error"; exit 1; }
  # a failed reset leaves the PREVIOUS image running; inspecting it would test the wrong binary
  st-flash --serial "$SERIAL" reset >/dev/null 2>&1 \
    || { echo "FAIL: st-flash reset failed — the board may still run the previous image (infrastructure)"; exit 1; }
fi
[ -f "$ELF" ] && [ -f "$BIN" ] || { echo "FAIL: $ELF / $BIN missing (make all, or pass --flash)"; exit 1; }
[ -f "$MAN" ] || { echo "FAIL: $MAN missing (make gen)"; exit 1; }

# --- 0. the board runs THIS image: its flash matches build/app.bin byte for byte -----------
# Symbol addresses come from the local ELF, so reading RAM on a board running anything else
# reads unrelated memory. A read-only run against another image is a SKIP, not a failure.
FL=$(mktemp); trap 'rm -f "$FL"' EXIT
st-flash --serial "$SERIAL" read "$FL" 0x08000000 "$(stat -c %s "$BIN")" >/dev/null 2>&1 \
  || { echo "FAIL: SWD flash read failed (infrastructure)"; exit 1; }
if ! cmp -s "$FL" "$BIN"; then
  [ "$FLASH" = 1 ] && { echo "FAIL: flash does not match $BIN after programming"; exit 1; }
  echo "SKIP: the board is not running this build of h735_app (run with --flash)"; exit 2
fi

sym() { arm-none-eabi-nm "$ELF" | awk -v s="$1" '$3==s {print "0x"$1; exit}'; }
RING=$(sym g_trace_ring); GCPU=$(sym g_cpu_mhz)
[ -n "$RING" ] && [ -n "$GCPU" ] || { echo "FAIL: could not resolve g_trace_ring / g_cpu_mhz"; exit 1; }
NREC=$(awk -F= '/^buffer_records/ {gsub(/[^0-9]/, "", $2); print $2; exit}' ecu.toml)
[ -n "$NREC" ] || { echo "FAIL: [trace].buffer_records not found in ecu.toml"; exit 1; }

# read <addr> <bytes> -> the bytes as u16 words, one per line; exits on ANY read failure
# (an empty read would otherwise compare equal to another empty read and pass as "frozen")
words() {
  local t; t=$(mktemp)
  st-flash --serial "$SERIAL" read "$t" "$1" "$2" >/dev/null 2>&1 || { rm -f "$t"; return 1; }
  [ "$(stat -c %s "$t")" = "$2" ] || { rm -f "$t"; return 1; }
  od -An -tu2 -v "$t" | tr -s ' ' '\n' | sed '/^$/d'; rm -f "$t"
}
mono_ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }

rc=0
fail() { echo "  FAIL: $*"; rc=1; }
ok()   { echo "  ok: $*"; }

# --- 1. the right board -------------------------------------------------------------------
W=$(words "$GCPU" 4) || { echo "FAIL: SWD read of g_cpu_mhz failed (infrastructure)"; exit 1; }
MHZ=$(head -1 <<<"$W")
[ "$MHZ" = 550 ] && ok "g_cpu_mhz = 550 (H735 on its 25 MHz HSE)" \
  || fail "g_cpu_mhz = $MHZ, want 550 — wrong board or mis-clocked image"

# --- 2/3. wait for the ring to freeze: two identical, non-empty reads ----------------------
# Load runs every 1 ms, so a capturing ring changes between any two reads a few hundred ms apart;
# identical reads mean it stopped. Bounded by a deadline, MONOTONIC so a clock step cannot cut it
# short. After --flash the trip lands within the first second or so of boot.
BYTES=$(( NREC * 8 ))
DEADLINE=$(( $(mono_ms) + 10000 ))
PREV=""; FROZEN=0; READS=0
while :; do
  CUR=$(words "$RING" "$BYTES") || { echo "FAIL: SWD ring read failed (infrastructure)"; exit 1; }
  READS=$(( READS + 1 ))
  if [ -n "$PREV" ] && [ "$CUR" = "$PREV" ]; then FROZEN=1; break; fi
  PREV=$CUR
  [ "$(mono_ms)" -ge "$DEADLINE" ] && break
  sleep 0.5
done

# in-RAM trace.Record: entity_id u16 | cpu_us u16 | tsinfo u32 (start_us bits 0-23, info 24-31)
# -> words w0 = eid, w1 = cpu_us, w2 = tsinfo low, w3 = tsinfo high (info = w3 >> 8)
IDS=$(awk -F, '/^[0-9]+,/ {print $1}' "$MAN" | tr '\n' ' ')
read -r NFB NOVR NBAD OVR_ID OVR_US MAXUS < <(awk -v ids="$IDS" '
  BEGIN { n = split(ids, a, " "); for (k = 1; k <= n; k++) known[a[k]] = 1 }
  { w[i++ % 4] = $1
    if (i % 4 == 0) {
      kind = int(w[0] / 16384); id = w[0] % 16384; info = int(w[3] / 256)
      if (kind != 2) next                                   # FB records only (epochs etc. skipped)
      fb++; if (w[1] > mx) mx = w[1]
      if (!(id in known)) bad++
      if (info % 2 == 1) { ovr++; if (ovr == 1) { oid = id; ous = w[1] } }
    } }
  END { print fb + 0, ovr + 0, bad + 0, (oid == "" ? "-" : oid), ous + 0, mx + 0 }' <<<"$CUR")

[ "$NFB" -gt 0 ] && ok "$NFB FB record(s) in the ${NREC}-record ring" \
  || fail "no FB records in g_trace_ring — the ring was never armed, or nothing was recorded"
if [ "$NFB" -gt 0 ]; then
  [ "$NBAD" = 0 ] && ok "every FB record's id is one $MAN names" \
    || fail "$NBAD FB record(s) carry an id the manifest does not name"
fi
# "unchanged" only means frozen for a ring that RECORDED something: a never-armed ring is all
# zeros, identical across reads, and must not read as "armed at boot" (mutant-tested)
if [ "$NFB" = 0 ]; then
  fail "ring empty — nothing to judge frozen-vs-capturing by (see the FB-record check above)"
elif [ "$FROZEN" = 1 ]; then
  ok "ring frozen (identical across reads, ${READS} read(s)) with no command sent — armed at boot"
else
  fail "ring still changing after 10 s — the overrun trigger never froze it"
fi
if [ "$NOVR" -gt 0 ]; then
  NAME=$(awk -F, -v id="$OVR_ID" '$1 == id {print $4 "." $5; exit}' "$MAN")
  ok "$NOVR OVERRAN record(s) — first: handler $OVR_ID ($NAME) at ${OVR_US}us (reported, not bounded)"
else
  fail "no record carries flag_overran — the freeze was not the overrun trigger"
fi
echo "  (longest FB duration in the window: ${MAXUS}us)"

[ "$rc" = 0 ] && echo "PASS: P3c-0 — the bare-metal superloop armed its ring at boot and the overrun trigger froze it" \
  || echo "FAILED"
exit $rc
