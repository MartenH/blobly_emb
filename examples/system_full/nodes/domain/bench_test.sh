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

# --- EVERY io point the manifest names, never hard-coded --------------------------
# manifest io row: <id>,io,<core>,io,<point name>,<period_us>,io
# All of them, not the first: REQ-IO-025 is a per-POINT guarantee, so checking one row would
# silently under-verify the moment a second point is configured (codex on #280).
mapfile -t IO_ROWS < <(awk -F, '$2=="io" && $4=="io"' "$MAN")
[ "${#IO_ROWS[@]}" -gt 0 ] \
  || { echo "FAIL: no io point row in $MAN — REQ-IO-025 requires a manifest row per point"; exit 1; }
echo "io points from manifest: ${#IO_ROWS[@]}"
for row in "${IO_ROWS[@]}"; do
  echo "  id=$(cut -d, -f1 <<<"$row") name=$(cut -d, -f5 <<<"$row") period=$(cut -d, -f6 <<<"$row")us"
done

# --- symbol addresses, resolved from the ELF -------------------------------------
sym() { arm-none-eabi-nm "$ELF" | awk -v s="$1" '$3==s {print "0x"$1; exit}'; }
RING=$(sym g_ring); HEAD=$(sym g_head); IOEXEC=$(sym g_io_exec_us); GCPU=$(sym g_cpu_mhz)
[ -n "$RING" ] && [ -n "$HEAD" ] && [ -n "$IOEXEC" ] && [ -n "$GCPU" ] \
  || { echo "FAIL: could not resolve a required symbol (g_ring/g_head/g_io_exec_us/g_cpu_mhz)"; exit 1; }

u32() { # u32() <addr> -> decimal on stdout, over SWD; nonzero status on ANY failure
  local t v; t=$(mktemp)
  st-flash --serial "$SERIAL" read "$t" "$1" 4 >/dev/null 2>&1 || { rm -f "$t"; return 1; }
  v=$(od -An -tu4 "$t" | tr -d ' \n'); rm -f "$t"
  # EMPTY is a failure too: st-flash can exit 0 having written nothing, and an empty value
  # becomes 0 in bash arithmetic — indistinguishable from a real reading of zero.
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}
# MONOTONIC time source: `date` is wall clock and can be stepped backwards by NTP or by hand
# mid-run, which shrinks a computed interval — or makes it negative — so a correctly advancing
# accumulator reads as impossible execution time; a forward step cuts an observation budget short.
# /proc/uptime is monotonic on Linux, and its 10ms granularity is irrelevant at these margins.
mono_us() { awk '{ printf "%d", $1 * 1000000 }' /proc/uptime; }

# read_u32 <addr> — a CHECKED counter read, into REPLY. A failed read is infrastructure, never a
# silent 0: bash treats an empty value as zero in arithmetic, so an unchecked baseline read that
# failed followed by a good second read yields a plausible positive delta and the liveness checks
# pass with no baseline at all (codex on #280).
#
# It assigns to REPLY rather than printing, because `exit` inside $( ) exits the SUBSHELL and not
# the script: the first version of this guard was INERT — the caller received the string
# "FAIL: SWD read ..." as its value, and bash then parsed `FAIL` as a variable name in arithmetic
# (`line 119: FAIL: unbound variable`). Found by stubbing st-flash to fail after the identity read.
read_u32() {
  REPLY=$(u32 "$1") || { echo "FAIL: SWD read of $1 failed (infrastructure)"; exit 1; }
  [ -n "$REPLY" ] || { echo "FAIL: SWD read of $1 returned nothing (infrastructure)"; exit 1; }
}

rc=0
fail() { echo "  FAIL: $*"; rc=1; }
ok()   { echo "  ok: $*"; }

# --- 1. the right board, running the right image ---------------------------------
read_u32 "$GCPU"; MHZ=$REPLY
[ "$MHZ" = 400 ] && ok "g_cpu_mhz = 400 (H755 on its 8 MHz HSE)" \
  || fail "g_cpu_mhz = $MHZ, want 400 — wrong board or mis-clocked image"

# --- 2. the recorder is live -------------------------------------------------------
# MODULO 2^32, for the same reason as g_io_exec_us below: g_head is an `unsigned` record counter
# and at ~4900 records/s it wraps about every ten days, so H2 < H1 is a healthy observation on a
# long-running board. I fixed this for the aggregate and left it here (codex on #280).
read_u32 "$HEAD"; H1=$REPLY; sleep 1; read_u32 "$HEAD"; H2=$REPLY
HDELTA=$(( (H2 - H1 + 4294967296) % 4294967296 ))
[ "$HDELTA" -gt 0 ] && ok "g_head advancing (+${HDELTA} records)" \
  || fail "g_head did not move from $H1 — the exec-hook recorder is not capturing"

# --- 3. the thread-level aggregate: it is still being published ---------------------
# LIVENESS ONLY, and deliberately so. This samples g_io_exec_us across a measured interval and
# asserts it moved and did not claim more time than the interval held. It does NOT establish that
# the sum equals the whole pass: a counter adding a constant would also advance, and five attempts
# at a quantitative floor for that were each wrong in one direction or the other (the reasons are
# at the ceiling check below). This description said otherwise for a round after the floor was
# removed — the script claiming more than it checks (codex on #280).
#
# The whole-pass claim is evidence from elsewhere, and all of it host-side in
# tools/loom2v/io_points_trace_test.v: t0 before the first point and t1 after the last point's
# record, io_exec_add publishing exactly `u32(t1 - t0)` and exactly once, on BOTH the load and
# trace-only paths, and every board glue's accumulator adding its own argument with a getter
# returning that same variable. Nothing on this node could separate a whole-pass sum from "only
# the last point's duration" anyway — with ONE io point they are the same number.
WIN_S=2
# The interval is MEASURED, not assumed. The nominal sleep is not the elapsed time: two SWD reads
# plus shell startup sit inside it, so a system legitimately spending nearly all its wall time in
# io service would exceed a ceiling built from the sleep alone — a false failure in exactly the
# slow-point case REQ-IO-025 exists to expose, which is the second time a nominal bound here would
# have inverted the requirement (codex on #280).
# MONOTONIC, not wall clock (mono_us, defined above the first check that needs it).
T1=$(mono_us); read_u32 "$IOEXEC"; A1=$REPLY; sleep "$WIN_S"; read_u32 "$IOEXEC"; A2=$REPLY; T2=$(mono_us)
ELAPSED_US=$(( T2 - T1 ))
# MODULO 2^32: g_io_exec_us is an `unsigned` C counter, so on a long-running target A2 < A1 is a
# perfectly healthy observation — it wrapped between the reads (~72 minutes of accumulated io time
# when a point consumes most of its period). Comparing the raw values would report a wrap as a
# stuck serve loop and never reach a valid delta (codex on #280).
DELTA=$(( (A2 - A1 + 4294967296) % 4294967296 ))
[ "$DELTA" -gt 0 ] || fail "g_io_exec_us did not move from $A1 across ${ELAPSED_US}us — the io serve loop is not running"

# --- 4. PER-POINT records in the ring, for EVERY point (the REQ-IO-025 claim) ------
# record (trace_hooks.c): eid u16 LE (kind<<14|id) | info u8 | start_us u24 LE | dur_us u16 LE.
# eid and dur are both u16-aligned (offsets 0 and 6), so -tu2 gives w0=eid .. w3=dur.
# The ring is a 256-record FLIGHT RECORDER: at ~4900 records/s it wraps in about 50ms, so a single
# snapshot is a ~50ms window. A point whose period exceeds that is simply absent from most
# snapshots — a 100ms point would be missing from roughly half of them — and asserting on one read
# would report a regression for a perfectly serviced point (codex on #280). So sample REPEATEDLY
# until every configured point has been seen, bounded by a deadline derived from the longest
# configured period. Only then is "no records for this point" evidence of anything.
MAXPER=0
for row in "${IO_ROWS[@]}"; do
  p=$(cut -d, -f6 <<<"$row"); [ "$p" -gt "$MAXPER" ] && MAXPER=$p
done
# 4 x the longest period, floor 2s: enough for several services of the slowest point
BUDGET_S=$(( (4 * MAXPER / 1000000) + 2 ))
declare -A CNT MINNZ MAXD
for row in "${IO_ROWS[@]}"; do ID=$(cut -d, -f1 <<<"$row"); CNT[$ID]=0; MINNZ[$ID]=0; MAXD[$ID]=0; done
SAMPLES=0
# MONOTONIC here too. I fixed the aggregate interval last round and left this deadline on the wall
# clock: a forward step exhausts the budget before a slow point has completed a period and reports
# its records missing, a backward step runs the bench far past its budget (codex on #280).
DEADLINE_US=$(( $(mono_us) + BUDGET_S * 1000000 ))
while :; do
  # The VALID window only. trace_arm() resets g_head WITHOUT clearing g_ring
  # (boards/common/trace_hooks.c), so on a read-only run after an arm the slots past the head still
  # hold records from the PREVIOUS capture, and counting them makes a point look serviced when this
  # capture has emitted nothing for it. trace_snapshot() bounds itself the same way:
  # n = min(g_head, RING_CAP), and for head < RING_CAP the writes started at slot 0 (codex on #280).
  read_u32 "$HEAD"; RH=$REPLY
  VALID=$(( RH < 256 ? RH : 256 ))
  RB=$(mktemp)
  st-flash --serial "$SERIAL" read "$RB" "$RING" 2048 >/dev/null 2>&1 \
    || { echo "FAIL: SWD ring read failed"; rm -f "$RB"; exit 1; }
  WORDS=$(od -An -tu2 -v "$RB" | tr -s ' ' '\n'); rm -f "$RB"
  SAMPLES=$(( SAMPLES + 1 ))
  for row in "${IO_ROWS[@]}"; do
    ID=$(cut -d, -f1 <<<"$row")
    read -r n _ mx _ nzmn < <(awk -v want=$(( (2 << 14) | ID )) -v valid="$VALID" '
      NF { w[i++ % 4] = $1; if (i % 4 == 0) { rec++; if (rec > valid) next
            if (w[0] == want) { c++; d = w[3]
            if (d > 0) { nz++; if (nzmn == "" || d < nzmn) nzmn = d }
            if (mn == "" || d < mn) mn = d; if (d > mx) mx = d } } }
      END { print c + 0, (mn == "" ? 0 : mn), mx + 0, nz + 0, (nzmn == "" ? 0 : nzmn) }' <<<"$WORDS")
    CNT[$ID]=$(( CNT[$ID] + n ))
    [ "$mx" -gt "${MAXD[$ID]}" ] && MAXD[$ID]=$mx
    if [ "$nzmn" -gt 0 ] && { [ "${MINNZ[$ID]}" = 0 ] || [ "$nzmn" -lt "${MINNZ[$ID]}" ]; }; then MINNZ[$ID]=$nzmn; fi
  done
  # Stop when every point has a record — which is exactly what is asserted below. This condition
  # has been both tighter and looser than the assertion at different points: it once required a
  # NONZERO duration too, which was right while a nonzero sample was demanded and wrong once 0us
  # became a valid duration (a sub-microsecond service records 0 correctly). Keep the two in step
  # — a loop that stops before its assertion can pass, or keeps sampling for something nothing
  # asserts, is wrong either way (codex on #280).
  MISSING=0
  for row in "${IO_ROWS[@]}"; do
    ID=$(cut -d, -f1 <<<"$row")
    [ "${CNT[$ID]}" -eq 0 ] && MISSING=1
  done
  [ "$MISSING" = 0 ] && break
  [ "$(mono_us)" -ge "$DEADLINE_US" ] && break
  sleep 0.05
done
echo "  (sampled the ring ${SAMPLES}x over up to ${BUDGET_S}s; longest configured period ${MAXPER}us)"

for row in "${IO_ROWS[@]}"; do
  ID=$(cut -d, -f1 <<<"$row"); NAME=$(cut -d, -f5 <<<"$row"); PER=$(cut -d, -f6 <<<"$row")
  if [ "${CNT[$ID]}" -gt 0 ]; then
    ok "${CNT[$ID]} record(s) for io point id $ID ($NAME) across ${SAMPLES} sample(s), max dur ${MAXD[$ID]}us"
    # A duration of 0 is NOT a failure. If a point's whole service begins and ends inside one
    # microsecond tick, every correctly bracketed record reads 0 — and REQ-IO-025 asks for the
    # point's own service duration, not for that service to be slow enough to measure. Requiring a
    # nonzero sample would fail a healthy fast point after exhausting the budget, which is the
    # fourth bound in this script that would have failed a good board (codex on #280).
    #
    # What rules out "the bracket records nothing" is stronger and deterministic: the host test
    # compares the emitted call against `u32(C.board_now_us() - p<hid>_t0)` exactly, so the
    # duration provably comes from that point's own bracket whatever value it takes.
    if [ "${MINNZ[$ID]}" -gt 0 ]; then
      ok "  durations measured (min nonzero ${MINNZ[$ID]}us, max ${MAXD[$ID]}us)"
    else
      echo "  note: every sampled duration for id $ID ($NAME) read 0us — a sub-microsecond service,"
      echo "        not a fault: the bracket itself is asserted host-side against the exact expression."
    fi
    # NO upper bound against the period here. A point that overruns its period is exactly what
    # REQ-IO-025 exists to make VISIBLE, so failing on it would invert the requirement — that is a
    # scheduling/timing concern belonging to its own requirement, not to observability
    # (codex on #280). The duration is reported above so an overrun is still evident in the log.
    if [ "${MAXD[$ID]}" -ge "$PER" ]; then
      echo "  note: id $ID ($NAME) recorded ${MAXD[$ID]}us against a ${PER}us period — an overrun, and"
      echo "        visible precisely because the per-point record exists. Not a failure of this check."
    fi
  else
    fail "no kind=FB records with id $ID ($NAME) in ${SAMPLES} ring sample(s) over ${BUDGET_S}s — that point's own service time is NOT observable"

  fi
done

# --- 5. the aggregate does not claim more than the wall clock allowed -----------------
# A ceiling, and deliberately NO quantitative floor. Five successive shapes of one were each
# wrong, alternating between admitting a regression and failing a healthy board:
#   passes x DMIN        vacuous — collapses to 0 when one sample rounds down
#   flat 0.5us/pass      admits an io_exec_add that ignores its argument and adds 1
#   >= passes x DMAX     admits that same adder by equality
#   >  passes x DMAX     fails a good board on a single quantized outlier
#   >  passes x DNZMIN   charges a nonzero duration to samples that legitimately measured 0
# The instrument cannot support one: the ring is a 256-record flight recorder that wraps in ~50ms
# and is sampled OUTSIDE the window being bounded, so there is no matched (work, interval) pair to
# calibrate against — and estimating the zero/nonzero split from five samples is calibration on
# noise. A bound that mis-fires in either direction is worse than an honest gap (codex on #280,
# five rounds on this one assertion).
#
# So what remains is what the bench can actually witness: the counter ADVANCES, and it cannot
# claim more time than the window held. The requirement's other half — that the sum brackets the
# WHOLE PASS rather than one point or a constant — is decided where it is decidable, in the
# emitted shape: tools/loom2v/io_points_trace_test.v asserts t0 precedes the first point, t1
# follows the last point's RECORD, and io_exec_add publishes exactly t1 - t0. Below that there is
# only the C one-liner `io_exec_add(us) { g_io_exec_us += us; }` in the board glue, which no
# instrument here reaches.
if [ "$DELTA" -gt 0 ]; then
  [ "$DELTA" -le "$ELAPSED_US" ] && ok "g_io_exec_us +${DELTA}us within the ${ELAPSED_US}us actually elapsed between the two reads" \
    || fail "g_io_exec_us advanced ${DELTA}us across a measured ${ELAPSED_US}us interval — more execution than wall time, which is impossible"
fi

[ "$rc" = 0 ] && echo "PASS: REQ-IO-025 — per-point io records observable on silicon" \
  || echo "FAILED"
exit $rc
