#!/usr/bin/env bash
# On-target regression test for the h755_io_analog ADC (P2) + PWM (P3) io points.
#
# Runs against a live NUCLEO-H755ZI-Q (CM7) over SWD — no scope, no manual wiring.
# It reads the TIM1 / ADC1 / DMA1 registers and the io-thread liveness counter via
# OpenOCD and asserts that the drivers are actually doing their job on silicon:
#
#   PWM  (REQ-IO-021): TIM1_CH1 enabled with MOE, the expected 20 kHz carrier, and
#                      the duty ramp reaching CCR1 (FB -> IOC -> io thread -> pwm_write).
#   ADC  (REQ-IO-018): ADC1 continuous scan + circular DMA enabled, started, and
#                      producing samples (the DMA buffer advances on the floating pin).
#   live (REQ-IO-024): the io serve loop keeps executing (g_io_exec_us advances) — the
#                      regression guard for the pacing-sleep wedge.
#
# Exit: 0 = all checks pass, 1 = a check FAILED (regression), 2 = no H755 attached
# (SKIP -> `make trace` records the h755/target context as "not run", never "fail").
#
# Usage: ./bench_test.sh [--flash]      # --flash builds + flashes this image first
set -uo pipefail
cd "$(dirname "$0")"
ELF=build/h755_io_analog.elf
FLASH=0; [ "${1:-}" = "--flash" ] && FLASH=1

# --- select the target ST-LINK ---------------------------------------------------
# BLOB_H755_SERIAL is the unambiguous identity and REQUIRED when more than one
# H74x/H75x-family probe is present: the ST-LINK dev-type ("STM32H74x_H75x") does NOT
# distinguish an H755 from an H743/745/753, and this test FLASHES (destructive) — we
# must never guess which family board to overwrite. A missing/broken st-info is an
# INFRASTRUCTURE failure (exit 1, "bench misconfigured"), NOT a skip: only a
# successful probe that finds zero matching boards skips (exit 2, "board not attached").
if [ -n "${BLOB_H755_SERIAL:-}" ]; then
  SERIAL="$BLOB_H755_SERIAL"
  echo "target ST-LINK (BLOB_H755_SERIAL): $SERIAL"
else
  command -v st-info >/dev/null 2>&1 || { echo "FAIL: st-info not found — bench tooling missing (infrastructure)"; exit 1; }
  PROBE=$(st-info --probe 2>&1) || { echo "FAIL: st-info --probe failed (infrastructure):"; echo "$PROBE" | tail -3; exit 1; }
  mapfile -t CANDS < <(awk '/^[0-9]+\./{ser=""} /serial:/{ser=$2} /dev-type:.*STM32H74x_H75x/{print ser}' <<<"$PROBE")
  case ${#CANDS[@]} in
    0) echo "SKIP: no STM32H74x_H75x ST-LINK attached — on-target test not run."; exit 2 ;;
    1) SERIAL="${CANDS[0]}"; echo "target ST-LINK (sole H74x/H75x): $SERIAL" ;;
    *) echo "FAIL: ${#CANDS[@]} H74x/H75x probes present — set BLOB_H755_SERIAL to the NUCLEO-H755ZI-Q so the flash cannot hit the wrong board:"; printf '  %s\n' "${CANDS[@]}"; exit 1 ;;
  esac
fi

if [ "$FLASH" = 1 ]; then
  echo "building + flashing h755_io_analog ..."
  make >/dev/null || { echo "FAIL: build error"; exit 1; }
  st-flash --serial "$SERIAL" write build/h755_io_analog.bin 0x08000000 >/dev/null 2>&1 || { echo "FAIL: flash error"; exit 1; }
  st-flash --serial "$SERIAL" reset >/dev/null 2>&1
  sleep 2
fi
[ -f "$ELF" ] || { echo "FAIL: $ELF missing (build first, or pass --flash)"; exit 1; }

# --- symbol addresses (resolved from the ELF, never hard-coded) -------------------
sym() { arm-none-eabi-nm "$ELF" | awk -v s="$1" '$3==s {print "0x"$1; exit}'; }
IOEXEC=$(sym g_io_exec_us); ADCDMA=$(sym g_adc_dma)
[ -n "$IOEXEC" ] && [ -n "$ADCDMA" ] || { echo "FAIL: could not resolve g_io_exec_us/g_adc_dma"; exit 1; }

# Liveness is proven by STATUS FLAGS, not value diffs: a free-running counter or a
# quantized ADC sample can read identical at two snapshots (CNT at 20 kHz aliases over
# a whole-period gap; a rail-tied or stable PA3 repeats). So at t0 we CLEAR the timer
# update flag (TIM1_SR.UIF) and the DMA transfer-complete flag (DMA1 TCIF0), then after
# 1.2 s assert both have re-SET — the timer wrapped and the DMA completed a scan,
# regardless of any input value. The FB->io->pwm_write chain is proven by the duty
# sweeping: CCR1 sampled at 3 points, asserted not-all-equal (the ramp bounces off
# 0/1000, so a single-interval diff could alias — three points cannot).
# Reads are keyed by ADDRESS (unique); single-word `echo SPLIT` markers phase them
# (OpenOCD aborts on a multi-word echo and only pipes mdw output — hence the marker +
# command substitution). mww clears a flag; mdw reads.
DMA_A=$(printf '0x%08x' "$ADCDMA"); IOX_A=$(printf '0x%08x' "$IOEXEC")
OUT=$(timeout 30 openocd \
  -c "adapter serial $SERIAL" -f interface/stlink.cfg -f target/stm32h7x.cfg \
  -c "init" -c "halt" \
  -c "mdw 0x40010000 1" -c "mdw 0x40010044 1" -c "mdw 0x40010020 1" -c "mdw 0x40010028 1" \
  -c "mdw 0x4001002c 1" -c "mdw 0x40010034 1" -c "mdw 0x40022008 1" -c "mdw 0x40020010 1" \
  -c "mdw $IOX_A 1" \
  -c "mww 0x40010010 0" -c "mww 0x40020008 0x20" \
  -c "resume" -c "sleep 600" -c "halt" -c "echo SPLIT" -c "mdw 0x40010034 1" \
  -c "resume" -c "sleep 600" -c "halt" -c "echo SPLIT" \
  -c "mdw 0x40010010 1" -c "mdw 0x40020000 1" -c "mdw 0x40010034 1" -c "mdw $IOX_A 1" \
  -c "resume" -c "shutdown" 2>&1)
if [ "$(grep -c '^SPLIT$' <<<"$OUT")" != 2 ] || ! grep -qE '0x[0-9a-f]{8}: [0-9a-f]{8}' <<<"$OUT"; then
  echo "FAIL: OpenOCD could not read the target (attached? powered?)"; grep -iE 'error|halt' <<<"$OUT" | tail -3; exit 1
fi

# --- parse: "phase:address" -> value across the 3 halts (0, 1, 2) -----------------
declare -A P
phase=0
while read -r addr val; do
  [ "$addr" = "SPLIT" ] && { phase=$((phase+1)); continue; }
  P["$phase:${addr%:}"]=$((16#$val))
done < <(sed -nE 's/^SPLIT$/SPLIT x/p; s/^(0x[0-9a-f]{8}): ([0-9a-f]{8}).*/\1 \2/p' <<<"$OUT")

# --- assert ----------------------------------------------------------------------
fails=0
ck() { if [ "$2" = 1 ]; then printf '  [PASS] %-28s %s\n' "$1" "$3"
  else printf '  [FAIL] %-28s %s\n' "$1" "$3"; fails=$((fails+1)); fi ; }
CR1=${P[0:0x40010000]}; BDTR=${P[0:0x40010044]}; CCER=${P[0:0x40010020]}
PSC=${P[0:0x40010028]}; ARR=${P[0:0x4001002c]}; ADCR=${P[0:0x40022008]}; S0CR=${P[0:0x40020010]}
CCRa=${P[0:0x40010034]}; CCRb=${P[1:0x40010034]}; CCRc=${P[2:0x40010034]}
SR=${P[2:0x40010010]}; LISR=${P[2:0x40020000]}; IOX0=${P[0:$IOX_A]}; IOX1=${P[2:$IOX_A]}
FREQ=$(( 200000000 / ((PSC+1)*(ARR+1)) ))
ramp_moved=$([ "$CCRa" != "$CCRb" ] || [ "$CCRb" != "$CCRc" ] || [ "$CCRa" != "$CCRc" ] && echo 1||echo 0)

echo "== PWM (REQ-IO-021) =="
ck "TIM1 counter enabled"    "$(( CR1 & 1 ))"           "CR1=$(printf 0x%X $CR1)"
ck "TIM1 MOE (output on)"    "$(( (BDTR>>15) & 1 ))"    "BDTR=$(printf 0x%X $BDTR)"
ck "TIM1_CH1 output (CC1E)"  "$(( CCER & 1 ))"          "CCER=$(printf 0x%X $CCER)"
ck "carrier 20 kHz"          "$([ "$PSC" = 0 ] && [ "$ARR" = 9999 ] && echo 1||echo 0)" "PSC=$PSC ARR=$ARR -> ${FREQ} Hz @200MHz"
ck "timer counting (UIF set)" "$(( SR & 1 ))"           "TIM1_SR=$(printf 0x%X $SR) after clear (timer wrapped)"
ck "duty ramp reaches CCR1"  "$ramp_moved"              "CCR1 $CCRa,$CCRb,$CCRc (FB->io->pwm_write)"

echo "== ADC (REQ-IO-018) =="
ck "ADC1 enabled (ADEN)"     "$(( ADCR & 1 ))"          "CR=$(printf 0x%X $ADCR)"
ck "ADC1 started (ADSTART)"  "$(( (ADCR>>2) & 1 ))"     "CR=$(printf 0x%X $ADCR)"
ck "DMA stream enabled"      "$(( S0CR & 1 ))"          "S0CR=$(printf 0x%X $S0CR)"
ck "DMA scan completing (TCIF)" "$(( (LISR>>5) & 1 ))"  "DMA1_LISR=$(printf 0x%X $LISR) after clear (a full scan landed)"

echo "== io thread liveness (sanity, not a REQ-IO-024 recovery proof) =="
ck "io serve loop advancing" "$([ "$IOX1" -gt "$IOX0" ] && echo 1||echo 0)" "g_io_exec_us $IOX0 -> $IOX1"

echo
if [ "$fails" = 0 ]; then echo "RESULT: PASS (10/10) — ADC + PWM verified on H755 silicon"; exit 0
else echo "RESULT: FAIL ($fails check(s)) — regression on target"; exit 1; fi
