#!/usr/bin/env bash
# On-target regression test for REQ-IO-025: the io thread's PER-POINT trace records.
#
# Runs against the live system_full `domain` node (NUCLEO-H755ZI-Q, CM7 + CM4 satellite)
# over SWD — no scope, no CAN, no manual wiring. With [trace] level = "all" the io serve
# loop brackets each POINT and pushes its own 8-byte record, so a slow ADC read or a pin
# that has begun misbehaving is visible in the very trace it delays. This asserts that on
# silicon:
#
#   REQ-IO-025: the exec-hook ring carries kind=FB records for the io point id the trace
#               manifest names, each with its OWN duration, AND the thread-level exec sum
#               (g_io_exec_us) keeps advancing — the aggregate the FB threads subtract as
#               preemption is unchanged, the per-point records are IN ADDITION to it.
#
# The point id and name come from gen/trace-manifest.csv, never hard-coded: the ids
# continue the global handler numbering, so a new handler shifts them.
#
# The recorder captures from reset (trace_hooks.c: g_capturing = 1), so no arm command —
# and therefore no CAN adapter — is needed to observe records. Reads are `st-flash read`
# of RAM, the same technique the bench serial map documents for g_cpu_mhz.
#
# Exit: 0 = pass, 1 = a check FAILED (regression) or the tooling is missing
# (infrastructure), 2 = SKIP (no board, or --flash without BLOB_H755_SERIAL).
#
# Usage: BLOB_H755_SERIAL=<serial> ./bench_test.sh [--flash]
set -uo pipefail
cd "$(dirname "$0")"
ELF=build/domain.elf
MAN=gen/trace-manifest.csv
FLASH=0; [ "${1:-}" = "--flash" ] && FLASH=1

# --- select the target ST-LINK ---------------------------------------------------
# Same rule as examples/h755_io_analog: the dev-type "STM32H74x_H75x" does not prove this
# is the H755 (an H743/745/753 reports the same), and this test FLASHES two banks, so
# flashing requires an explicit serial. A read-only run may auto-pick a sole 0x450 probe.
if [ -n "${BLOB_H755_SERIAL:-}" ]; then
  SERIAL="$BLOB_H755_SERIAL"
  echo "target ST-LINK (BLOB_H755_SERIAL): $SERIAL"
else
  command -v st-info >/dev/null 2>&1 || { echo "FAIL: st-info not found — bench tooling missing (infrastructure)"; exit 1; }
  PROBE=$(st-info --probe 2>&1) || { echo "FAIL: st-info --probe failed (infrastructure)"; exit 1; }
  mapfile -t CANDS < <(awk '/^[0-9]+\./{ser=""} /serial:/{ser=$2} /dev-type:.*STM32H74x_H75x/{print ser}' <<<"$PROBE")
  if [ "${#CANDS[@]}" = 0 ]; then
    echo "SKIP: no STM32H74x_H75x ST-LINK attached — on-target test not run."; exit 2
  elif [ "$FLASH" = 1 ]; then
    echo "SKIP: --flash needs BLOB_H755_SERIAL (the dev-type cannot confirm the H755). Candidates:"; printf '  %s\n' "${CANDS[@]}"; exit 2
  elif [ "${#CANDS[@]}" = 1 ]; then
    SERIAL="${CANDS[0]}"; echo "target ST-LINK (sole H74x/H75x, read-only): $SERIAL"
  else
    echo "SKIP: ${#CANDS[@]} H74x/H75x probes — set BLOB_H755_SERIAL:"; printf '  %s\n' "${CANDS[@]}"; exit 2
  fi
fi

if [ "$FLASH" = 1 ]; then
  echo "building + flashing domain (CM7 bank 1) and its CM4 satellite (bank 2) ..."
  make >/dev/null 2>&1 || { echo "FAIL: build error (domain)"; exit 1; }
  make -C ../domain_m4 >/dev/null 2>&1 || { echo "FAIL: build error (domain_m4)"; exit 1; }
  st-flash --serial "$SERIAL" write ../domain_m4/build/domain_m4.bin 0x08100000 >/dev/null 2>&1 || { echo "FAIL: flash error (bank 2)"; exit 1; }
  st-flash --serial "$SERIAL" write build/domain.bin 0x08000000 >/dev/null 2>&1 || { echo "FAIL: flash error (bank 1)"; exit 1; }
  st-flash --serial "$SERIAL" reset >/dev/null 2>&1
  sleep 3
fi
[ -f "$ELF" ] || { echo "FAIL: $ELF missing (build first, or pass --flash)"; exit 1; }
[ -f "$MAN" ] || { echo "FAIL: $MAN missing (run make gen)"; exit 1; }

# --- the io point the manifest names (id + name), never hard-coded ----------------
# manifest io row: <id>,io,<core>,io,<point name>,<period_us>,io
IO_ROW=$(awk -F, '$2=="io" && $4=="io" {print; exit}' "$MAN")
[ -n "$IO_ROW" ] && IO_ID=$(cut -d, -f1 <<<"$IO_ROW") && IO_NAME=$(cut -d, -f5 <<<"$IO_ROW") \
  && IO_PERIOD_US=$(cut -d, -f6 <<<"$IO_ROW") \
  || { echo "FAIL: no io point row in $MAN — REQ-IO-025 requires a manifest row per point"; exit 1; }
echo "io point from manifest: id=$IO_ID name=$IO_NAME period=${IO_PERIOD_US}us"

# --- symbol addresses, resolved from the ELF -------------------------------------
sym() { arm-none-eabi-nm "$ELF" | awk -v s="$1" '$3==s {print "0x"$1; exit}'; }
RING=$(sym g_ring); HEAD=$(sym g_head); IOEXEC=$(sym g_io_exec_us); GCPU=$(sym g_cpu_mhz)
[ -n "$RING" ] && [ -n "$HEAD" ] && [ -n "$IOEXEC" ] && [ -n "$GCPU" ] \
  || { echo "FAIL: could not resolve a required symbol (g_ring/g_head/g_io_exec_us/g_cpu_mhz)"; exit 1; }

u32() { # u32() <addr> -> decimal, over SWD
  local t; t=$(mktemp)
  st-flash --serial "$SERIAL" read "$t" "$1" 4 >/dev/null 2>&1 || { rm -f "$t"; return 1; }
  od -An -tu4 "$t" | tr -d ' \n'; rm -f "$t"
}

rc=0
fail() { echo "  FAIL: $*"; rc=1; }
ok()   { echo "  ok: $*"; }

# --- 1. the right board, running the right image ---------------------------------
MHZ=$(u32 "$GCPU") || { echo "FAIL: SWD read failed (infrastructure)"; exit 1; }
[ "$MHZ" = 400 ] && ok "g_cpu_mhz = 400 (H755 on its 8 MHz HSE)" \
  || fail "g_cpu_mhz = $MHZ, want 400 — wrong board or mis-clocked image"

# --- 2. the recorder is live -------------------------------------------------------
H1=$(u32 "$HEAD"); sleep 1; H2=$(u32 "$HEAD")
[ "$H2" -gt "$H1" ] && ok "g_head advancing ($H1 -> $H2)" \
  || fail "g_head stuck at $H1 — the exec-hook recorder is not capturing"

# --- 3. the thread-level aggregate still advances (the exclusion sum) --------------
A1=$(u32 "$IOEXEC"); sleep 1; A2=$(u32 "$IOEXEC")
[ "$A2" -gt "$A1" ] && ok "g_io_exec_us advancing ($A1 -> $A2) — the pass is still summed for preemption exclusion" \
  || fail "g_io_exec_us stuck at $A1 — the io serve loop is not running"

# --- 4. PER-POINT records in the ring (the REQ-IO-025 claim) -----------------------
# record (trace_hooks.c): eid u16 LE (kind<<14|id) | info u8 | start_us u24 LE | dur_us u16 LE.
# eid and dur are both u16-aligned (offsets 0 and 6), so -tu2 gives w0=eid .. w3=dur.
RB=$(mktemp)
st-flash --serial "$SERIAL" read "$RB" "$RING" 2048 >/dev/null 2>&1 || { echo "FAIL: SWD ring read failed"; rm -f "$RB"; exit 1; }
read -r NREC DMIN DMAX NNZ < <(od -An -tu2 -v "$RB" | tr -s ' ' '\n' | awk -v want=$(( (2 << 14) | IO_ID )) '
  NF { w[n++ % 4] = $1; if (n % 4 == 0) { if (w[0] == want) { c++; d = w[3]; if (d > 0) nz++;
        if (mn == "" || d < mn) mn = d; if (d > mx) mx = d } } }
  END { print c + 0, (mn == "" ? 0 : mn), mx + 0, nz + 0 }')
rm -f "$RB"
[ "${NREC:-0}" -gt 0 ] && ok "$NREC record(s) for io point id $IO_ID ($IO_NAME), dur ${DMIN}..${DMAX}us" \
  || fail "no kind=FB records with id $IO_ID in the ring — the io point's own service time is NOT observable"
# Its OWN duration, so the records must carry a real measurement — not merely a number that
# happens to satisfy an upper bound. If the generated bracket regressed to pass zero for every
# point, NREC would still be positive and DMAX=0 would pass a bound-only check, and this test
# would report the service time "observable" while containing no timing at all (codex on #280).
# At least one nonzero, not all: the DWT gives microsecond resolution and a single register
# write can genuinely round to 0, so requiring every sample to be nonzero would be flaky.
if [ "${NREC:-0}" -gt 0 ]; then
  [ "${NNZ:-0}" -gt 0 ] && ok "${NNZ}/${NREC} record(s) carry a measured duration (max ${DMAX}us)" \
    || fail "all ${NREC} records for id $IO_ID have dur_us = 0 — the bracket is recording no time, so the point's own service duration is NOT observable"
  [ "$DMAX" -lt "$IO_PERIOD_US" ] && ok "durations within the point's ${IO_PERIOD_US}us period" \
    || fail "a point service took ${DMAX}us, its period is ${IO_PERIOD_US}us"
fi

[ "$rc" = 0 ] && echo "PASS: REQ-IO-025 — per-point io records observable on silicon" \
  || echo "FAILED"
exit $rc
