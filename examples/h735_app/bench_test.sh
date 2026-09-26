#!/usr/bin/env bash
# On-target regression test for P3c-0: the bare-metal superloop as the single-core trace runner
# (docs/trace-multicore.md §5.0) — examples/h735_app on the STM32H735G-DK, over SWD only.
#
# No CAN adapter and no host command: the generated superloop ARMS the ring at boot, and the
# Governor ramps Load past its 500 us budget within the first second, so the overrun trigger
# freezes the ring by itself. This script flashes the image, resets it, and reads that frozen
# window straight out of RAM (g_trace_ring, in-RAM trace.Record), asserting what only a working
# runner produces:
#
#   1. the right board: g_cpu_mhz = 550 (an H723 on this image locks at 64 — bench notes)
#   2. the ring holds FB records, every id one the trace manifest names
#   3. the ring is FROZEN — identical across reads while the core is still in thread mode
#      (ICSR.VECTACTIVE = 0, so not wedged in a fault handler) — with no command sent, so it
#      armed itself at boot and something stopped it on target
#   4. at least one record carries flag_overran — the freeze came with the trigger's culprit
#
# ALWAYS flashes and resets. A fresh boot is what makes the RAM window meaningful: TraceBuffer's
# start() rewinds the ring without clearing it, so after a host re-arm a read-only look could see
# records from an earlier capture (self-review). What it does NOT separate: a deliberate host stop
# landing after the trigger (the freeze cause lives in g_tm, whose layout this script does not
# parse); with nothing on the bus sending 0x7EC that does not happen.
#
# Durations are REPORTED, not bounded: the trip time and the overrunning duration depend on the
# Governor's ramp and the core's timing, and a bound on either is a check that can fail a
# healthy board (the lesson of examples/system_full/nodes/domain/bench_test.sh).
#
# Exit: 0 = pass, 1 = FAILED (regression) or tooling missing, 2 = SKIP (no --flash, no serial,
# or no board). Needs st-flash/st-info and arm-none-eabi-nm — no OpenOCD, no CAN.
#
# Usage: BLOB_H735_SERIAL=<serial> ./bench_test.sh --flash
#   The serial is required: an H735 and an H723 report the same chip id, and this overwrites
#   whatever the board holds (on the system_full bench: sysnode's image — reflash it from
#   examples/system_full/nodes/sysnode afterwards).
set -uo pipefail
cd "$(dirname "$0")"
ELF=build/app.elf
BIN=build/app.bin
MAN=gen/trace-manifest.csv

[ "${1:-}" = "--flash" ] || { echo "SKIP: this test flashes the board — pass --flash"; exit 2; }
for t in st-info st-flash arm-none-eabi-nm od; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: $t not found — bench tooling missing (infrastructure)"; exit 1; }
done
[ -n "${BLOB_H735_SERIAL:-}" ] || { echo "SKIP: BLOB_H735_SERIAL not set (an H735 and an H723 look alike to st-info)"; exit 2; }
SERIAL=$BLOB_H735_SERIAL
PROBE=$(st-info --probe 2>&1) || { echo "FAIL: st-info --probe failed (infrastructure)"; exit 1; }
grep -q "$SERIAL" <<<"$PROBE" || { echo "SKIP: ST-LINK $SERIAL not attached — on-target test not run"; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "building + flashing h735_app ..."
make all >"$TMP/build.log" 2>&1 || { echo "FAIL: build error:"; tail -15 "$TMP/build.log"; exit 1; }
# the ring's address AND size from the ELF about to be flashed — never from ecu.toml, which can
# drift from what was compiled in — resolved BEFORE flashing, so a failure here costs no reflash.
# The size is converted by the shell: strtonum() is gawk-only, and mawk has no such function
# (codex on #284).
read -r RING RSIZE_HEX < <(arm-none-eabi-nm -S "$ELF" | awk '$4 == "g_trace_ring" {print "0x"$1, $2; exit}')
GCPU=$(arm-none-eabi-nm "$ELF" | awk '$3 == "g_cpu_mhz" {print "0x"$1; exit}')
[ -n "${RING:-}" ] && [ -n "$GCPU" ] && [[ "${RSIZE_HEX:-}" =~ ^[0-9a-fA-F]+$ ]] \
  || { echo "FAIL: could not resolve g_trace_ring / g_cpu_mhz in $ELF"; exit 1; }
RSIZE=$(( 16#$RSIZE_HEX ))
NREC=$(( RSIZE / 8 ))
[ "$NREC" -gt 0 ] || { echo "FAIL: g_trace_ring has size 0 in $ELF"; exit 1; }
st-flash --serial "$SERIAL" write "$BIN" 0x08000000 >/dev/null 2>&1 || { echo "FAIL: flash error"; exit 1; }
# a failed reset leaves the PREVIOUS image running; inspecting it would test the wrong binary
st-flash --serial "$SERIAL" reset >/dev/null 2>&1 \
  || { echo "FAIL: st-flash reset failed — the board may still run the previous image (infrastructure)"; exit 1; }
[ -f "$MAN" ] || { echo "FAIL: $MAN missing after the build"; exit 1; }

# read <addr> <bytes> -> the bytes as u16 words, one per line; fails on ANY short or failed read
# (an empty read would otherwise compare equal to another empty read and pass as "frozen")
words() {
  st-flash --serial "$SERIAL" read "$TMP/rd" "$1" "$2" >/dev/null 2>&1 || return 1
  [ "$(stat -c %s "$TMP/rd")" = "$2" ] || return 1
  od -An -tu2 -v "$TMP/rd" | tr -s ' ' '\n' | sed '/^$/d'
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

# --- 2/3. wait for the ring to freeze: two identical reads -------------------------------------
# Load runs every 1 ms, so a capturing ring changes between any two reads a few hundred ms apart;
# identical reads mean it stopped. Bounded by a deadline, MONOTONIC so a clock step cannot cut it
# short. After the reset the trip lands within the first second or so of boot.
DEADLINE=$(( $(mono_ms) + 10000 ))
PREV=""; FROZEN=0; READS=0
while :; do
  CUR=$(words "$RING" "$RSIZE") || { echo "FAIL: SWD ring read failed (infrastructure)"; exit 1; }
  READS=$(( READS + 1 ))
  if [ -n "$PREV" ] && [ "$CUR" = "$PREV" ]; then FROZEN=1; break; fi
  PREV=$CUR
  [ "$(mono_ms)" -ge "$DEADLINE" ] && break
  sleep 0.5
done

# An unchanged ring also describes a core that faulted after recording. The superloop runs in
# thread mode with no peripheral IRQs, so ICSR.VECTACTIVE (bits 8:0) must read 0 — sampled a few
# times, since one read could land in a transient. A thread-mode hang is not separated from a
# healthy loop by this; the fault case is.
ACTIVE=0
for _ in 1 2 3; do
  W=$(words 0xE000ED04 4) || { echo "FAIL: SWD read of ICSR failed (infrastructure)"; exit 1; }
  lo=$(sed -n 1p <<<"$W"); v=$(( lo & 0x1ff ))
  [ "$v" -ne 0 ] && ACTIVE=$v
  sleep 0.2
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

if [ "$NFB" -gt 0 ]; then
  ok "$NFB FB record(s) in the ${NREC}-record ring"
  [ "$NBAD" = 0 ] && ok "every FB record's id is one $MAN names" \
    || fail "$NBAD FB record(s) carry an id the manifest does not name"
else
  fail "no FB records in g_trace_ring — the ring was never armed, or nothing was recorded"
fi
# "unchanged" only means frozen for a ring that RECORDED something on a core still running
# thread code: a never-armed ring is all zeros and a faulted core stops writing — neither may
# read as "armed at boot"
if [ "$NFB" = 0 ]; then
  fail "ring empty — nothing to judge frozen-vs-capturing by (see the FB-record check above)"
elif [ "$ACTIVE" -ne 0 ]; then
  fail "the core is in exception $ACTIVE (ICSR.VECTACTIVE) — an unchanged ring there is a stopped CPU, not a frozen trace"
elif [ "$FROZEN" = 1 ]; then
  ok "ring frozen (identical across reads, ${READS} read(s)), core in thread mode, no command sent — armed at boot"
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
