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

# --- locate the H755 ST-LINK by chip id (0x450 = STM32H74x_H75x) ------------------
SERIAL=$(st-info --probe 2>/dev/null | awk '
  /^[0-9]+\./ {ser=""} /serial:/ {ser=$2} /dev-type:.*STM32H74x_H75x/ {print ser; exit}')
if [ -z "${SERIAL:-}" ]; then
  echo "SKIP: no STM32H74x_H75x (NUCLEO-H755ZI-Q) ST-LINK found — on-target test not run."
  exit 2
fi
echo "H755 ST-LINK: $SERIAL"

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

# Read every register/symbol keyed by its ADDRESS (unique), with one single-word
# `echo SPLIT` marker separating the t0 snapshot from the t1 one 1.2 s later.
# (OpenOCD aborts the -c sequence on a multi-word echo, and only emits mdw output
# down a pipe — so: single-word marker, captured via command substitution.)
DMA_A=$(printf '0x%08x' "$ADCDMA"); IOX_A=$(printf '0x%08x' "$IOEXEC")
OUT=$(timeout 25 openocd \
  -c "adapter serial $SERIAL" -f interface/stlink.cfg -f target/stm32h7x.cfg \
  -c "init" -c "halt" \
  -c "mdw 0x40010000 1" -c "mdw 0x40010044 1" -c "mdw 0x40010020 1" -c "mdw 0x40010028 1" \
  -c "mdw 0x4001002c 1" -c "mdw 0x40010024 1" -c "mdw 0x40010034 1" -c "mdw 0x40022008 1" \
  -c "mdw 0x40020010 1" -c "mdw $DMA_A 1"     -c "mdw $IOX_A 1" \
  -c "resume" -c "sleep 1200" -c "halt" -c "echo SPLIT" \
  -c "mdw 0x40010024 1" -c "mdw 0x40010034 1" -c "mdw $DMA_A 1" -c "mdw $IOX_A 1" \
  -c "resume" -c "shutdown" 2>&1)
if ! grep -q 'SPLIT' <<<"$OUT" || ! grep -qE '0x[0-9a-f]{8}: [0-9a-f]{8}' <<<"$OUT"; then
  echo "FAIL: OpenOCD could not read the target (attached? powered?)"; grep -iE 'error|halt' <<<"$OUT" | tail -3; exit 1
fi

# --- parse: address -> value, split into the t0 map (V) and t1 map (W) -----------
declare -A V W
phase=0
while read -r addr val; do
  [ "$addr" = "SPLIT" ] && { phase=1; continue; }
  a="${addr%:}"
  if [ "$phase" = 0 ]; then V[$a]=$((16#$val)); else W[$a]=$((16#$val)); fi
done < <(sed -nE 's/^SPLIT$/SPLIT x/p; s/^(0x[0-9a-f]{8}): ([0-9a-f]{8}).*/\1 \2/p' <<<"$OUT")

# --- assert ----------------------------------------------------------------------
fails=0
ck() { if [ "$2" = 1 ]; then printf '  [PASS] %-28s %s\n' "$1" "$3"
  else printf '  [FAIL] %-28s %s\n' "$1" "$3"; fails=$((fails+1)); fi ; }
DMA0=$(( V[$DMA_A] & 0xFFFF )); DMA1=$(( W[$DMA_A] & 0xFFFF ))
FREQ=$(( 200000000 / ((V[0x40010028]+1)*(V[0x4001002c]+1)) ))

echo "== PWM (REQ-IO-021) =="
ck "TIM1 counter enabled"    "$(( V[0x40010000] & 1 ))"             "CR1=$(printf 0x%X ${V[0x40010000]})"
ck "TIM1 MOE (output on)"    "$(( (V[0x40010044]>>15) & 1 ))"      "BDTR=$(printf 0x%X ${V[0x40010044]})"
ck "TIM1_CH1 output (CC1E)"  "$(( V[0x40010020] & 1 ))"            "CCER=$(printf 0x%X ${V[0x40010020]})"
ck "carrier 20 kHz"          "$([ "${V[0x40010028]}" = 0 ] && [ "${V[0x4001002c]}" = 9999 ] && echo 1||echo 0)" "PSC=${V[0x40010028]} ARR=${V[0x4001002c]} -> ${FREQ} Hz @200MHz"
ck "timer counting"          "$([ "${V[0x40010024]}" != "${W[0x40010024]}" ] && echo 1||echo 0)" "CNT ${V[0x40010024]} -> ${W[0x40010024]}"
ck "duty ramp reaches CCR1"  "$([ "${V[0x40010034]}" != "${W[0x40010034]}" ] && echo 1||echo 0)" "CCR1 ${V[0x40010034]} -> ${W[0x40010034]} (FB->io->pwm_write)"

echo "== ADC (REQ-IO-018) =="
ck "ADC1 enabled (ADEN)"     "$(( V[0x40022008] & 1 ))"           "CR=$(printf 0x%X ${V[0x40022008]})"
ck "ADC1 started (ADSTART)"  "$(( (V[0x40022008]>>2) & 1 ))"      "CR=$(printf 0x%X ${V[0x40022008]})"
ck "DMA stream enabled"      "$(( V[0x40020010] & 1 ))"           "S0CR=$(printf 0x%X ${V[0x40020010]})"
ck "conversions producing"   "$([ "$DMA0" != "$DMA1" ] && echo 1||echo 0)" "sample $DMA0 -> $DMA1 (scan+DMA live)"

echo "== io thread liveness (REQ-IO-024) =="
ck "io serve loop advancing" "$([ "${W[$IOX_A]}" -gt "${V[$IOX_A]}" ] && echo 1||echo 0)" "g_io_exec_us ${V[$IOX_A]} -> ${W[$IOX_A]} (no pacing wedge)"

echo
if [ "$fails" = 0 ]; then echo "RESULT: PASS (11/11) — ADC + PWM + io thread verified on H755 silicon"; exit 0
else echo "RESULT: FAIL ($fails check(s)) — regression on target"; exit 1; fi
