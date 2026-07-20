#!/usr/bin/env bash
# On-target regression test for the h755_io_analog ADC (P2) + PWM (P3) io points.
#
# Runs against a live NUCLEO-H755ZI-Q (CM7) over SWD — no scope, no manual wiring.
# It reads the TIM1 / ADC1 / DMA1 registers and the io-thread liveness counter via
# OpenOCD and asserts that the drivers are actually doing their job on silicon:
#
#   PWM (REQ-IO-021): TIM1_CH1 enabled with MOE, the expected 20 kHz carrier, and
#                     the duty ramp reaching CCR1 (FB -> IOC -> io thread -> pwm_write).
#   ADC (REQ-IO-018): ADC1 continuous scan + circular DMA enabled + started, a scan
#                     COMPLETING (TCIF), the DMA pointed at g_adc_dma, AND the io thread
#                     reading it wait-free -> the value published on the bus tracks the
#                     live DMA array (the read path REQ-IO-018 requires).
#
# It also asserts the io serve loop keeps advancing (g_io_exec_us), a liveness sanity —
# NOT a REQ-IO-024 claim: that requirement is recovery after an anomalous clock sample,
# which this test does not inject (it stays analysis-argued).
#
# Exit: 0 = all checks pass, 1 = a check FAILED (regression), 2 = SKIP (no board, or a
# flash requested without BLOB_H755_SERIAL). A missing/broken probe tool is exit 1
# (infrastructure), never a silent skip.
#
# Usage: BLOB_H755_SERIAL=<serial> ./bench_test.sh [--flash]
set -uo pipefail
cd "$(dirname "$0")"
ELF=build/h755_io_analog.elf
FLASH=0; [ "${1:-}" = "--flash" ] && FLASH=1

# --- select the target ST-LINK ---------------------------------------------------
# BLOB_H755_SERIAL is the positive identity. The ST-LINK dev-type ("STM32H74x_H75x")
# does NOT distinguish an H755 from an H743/745/753, so a family probe alone can never
# confirm the board — and this test FLASHES (destructive). Rule: FLASHING requires an
# explicit BLOB_H755_SERIAL; the read-only path may auto-pick a sole family probe. A
# missing/broken st-info is INFRASTRUCTURE (exit 1), not a skip.
if [ -n "${BLOB_H755_SERIAL:-}" ]; then
  SERIAL="$BLOB_H755_SERIAL"
  echo "target ST-LINK (BLOB_H755_SERIAL): $SERIAL"
else
  command -v st-info >/dev/null 2>&1 || { echo "FAIL: st-info not found — bench tooling missing (infrastructure)"; exit 1; }
  PROBE=$(st-info --probe 2>&1) || { echo "FAIL: st-info --probe failed (infrastructure):"; echo "$PROBE" | tail -3; exit 1; }
  mapfile -t CANDS < <(awk '/^[0-9]+\./{ser=""} /serial:/{ser=$2} /dev-type:.*STM32H74x_H75x/{print ser}' <<<"$PROBE")
  if [ "${#CANDS[@]}" = 0 ]; then
    echo "SKIP: no STM32H74x_H75x ST-LINK attached — on-target test not run."; exit 2
  elif [ "$FLASH" = 1 ]; then
    echo "SKIP: --flash needs BLOB_H755_SERIAL — the H74x/H75x dev-type cannot confirm this is the H755 (won't risk flashing an H743/745/753). Set BLOB_H755_SERIAL to the board's ST-LINK serial:"; printf '  %s\n' "${CANDS[@]}"; exit 2
  elif [ "${#CANDS[@]}" = 1 ]; then
    SERIAL="${CANDS[0]}"; echo "target ST-LINK (sole H74x/H75x, read-only): $SERIAL"
  else
    echo "SKIP: ${#CANDS[@]} H74x/H75x probes — set BLOB_H755_SERIAL to pick the board:"; printf '  %s\n' "${CANDS[@]}"; exit 2
  fi
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
IOEXEC=$(sym g_io_exec_us); ADCDMA=$(sym g_adc_dma); IOCPOOL=$(sym g_ioc_pool); GCPU=$(sym g_cpu_mhz)
IOCARENA=$(sym g_ioc_arena)
[ -n "$IOEXEC" ] && [ -n "$ADCDMA" ] && [ -n "$IOCPOOL" ] && [ -n "$IOCARENA" ] && [ -n "$GCPU" ] || { echo "FAIL: could not resolve a required symbol"; exit 1; }
GCPU_A=$(printf '0x%08x' "$GCPU")
# IOC cell 2 = the Pot signal the io thread publishes (ioc_pub(2, adc_read_checked(1))).
# Size-proportional layout (ioc.h): payload slots live in g_ioc_arena — each pool row is
# IOC_ARENA_BYTES(sizeof(sig_t)) = 32 B (3 x 8 B, line-rounded), slot k at row + k*8. The
# ioc_t cell itself holds the arena pointer (+0), size (+4), then `shared` (byte +6),
# `wr` (+7), `rd` (+8). ioc_read leaves the latest CONSUMED value in slot[rd] and points
# `shared` at a stale spare — so the published slot is slot[shared&3] only while FRESH
# (bit2) is set, else slot[rd] (codex #156r3). Comparing that slot's `a` to g_adc_dma
# corroborates the io thread's read path; it is NOT a deterministic proof (a stable input
# keeps the boot sample within tolerance even if the periodic read broke), so the
# read-VALUE logic is additionally covered by the host e2e (examples/io_adc).
ROW2=$(( IOCARENA + 2*32 ))
S0=$(printf '0x%08x' $ROW2); S1=$(printf '0x%08x' $((ROW2+8))); S2=$(printf '0x%08x' $((ROW2+16)))
SH=$(printf '0x%08x' $(( IOCPOOL + 2*32 + 6 )))
M0AR=0x4002001c # DMA1 Stream0 M0AR (destination address register)

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
  -c "mdw $IOX_A 1" -c "mdw $GCPU_A 1" -c "mdw 0x58024418 1" -c "mdw 0x5802441c 1" -c "mdw 0x58024410 1" \
  -c "mww 0x40010010 0" -c "mww 0x40020008 0x20" \
  -c "resume" -c "sleep 600" -c "halt" -c "echo SPLIT" -c "mdw 0x40010034 1" \
  -c "resume" -c "sleep 600" -c "halt" -c "echo SPLIT" \
  -c "mdw 0x40010010 1" -c "mdw 0x40020000 1" -c "mdw 0x40010034 1" -c "mdw $IOX_A 1" \
  -c "mdw $M0AR 1" -c "mdw $DMA_A 1" -c "mdw $S0 1" -c "mdw $S1 1" -c "mdw $S2 1" -c "mdw $SH 1" \
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
fails=0; total=0
ck() { total=$((total+1)); if [ "$2" = 1 ]; then printf '  [PASS] %-30s %s\n' "$1" "$3"
  else printf '  [FAIL] %-30s %s\n' "$1" "$3"; fails=$((fails+1)); fi ; }
CR1=${P[0:0x40010000]}; BDTR=${P[0:0x40010044]}; CCER=${P[0:0x40010020]}
PSC=${P[0:0x40010028]}; ARR=${P[0:0x4001002c]}; ADCR=${P[0:0x40022008]}; S0CR=${P[0:0x40020010]}
CCRa=${P[0:0x40010034]}; CCRb=${P[1:0x40010034]}; CCRc=${P[2:0x40010034]}
SR=${P[2:0x40010010]}; LISR=${P[2:0x40020000]}; IOX0=${P[0:$IOX_A]}; IOX1=${P[2:$IOX_A]}
ramp_moved=$([ "$CCRa" != "$CCRb" ] || [ "$CCRb" != "$CCRc" ] || [ "$CCRa" != "$CCRc" ] && echo 1||echo 0)
# carrier: DERIVE the timer clock from the achieved SYSCLK (g_cpu_mhz, 0/64 if PLL
# bring-up degraded) and the ACTUAL RCC prescalers, not a hard-coded 200 MHz (codex #156r3).
# H7 tree: HCLK = SYSCLK/HPRE(D1CFGR[3:0]); PCLK2 = HCLK/D2PPRE2(D2CFGR[10:8]); the timer
# kernel clock = PCLK2 if that prescaler is /1, else 2xPCLK2 (TIMPRE=0) or 4xPCLK2 (TIMPRE=1).
GCPU_MHZ=${P[0:$GCPU_A]}; D1=${P[0:0x58024418]}; D2=${P[0:0x5802441c]}; CFGR=${P[0:0x58024410]}
hpre=$(( D1 & 0xF ));  hdiv=$([ "$hpre"  -ge 8 ] && echo $((1 << (hpre-7)))  || echo 1)
ppre2=$(( (D2>>8)&0x7 )); pdiv=$([ "$ppre2" -ge 4 ] && echo $((1 << (ppre2-3))) || echo 1)
timpre=$(( (CFGR>>15)&1 )); hclk=$(( GCPU_MHZ*1000000 / hdiv )); pclk2=$(( hclk / pdiv ))
if [ "$pdiv" -eq 1 ]; then tclk=$pclk2; elif [ "$timpre" -eq 0 ]; then tclk=$(( 2*pclk2 )); else tclk=$(( 4*pclk2 )); fi
FREQ=$(( tclk / ((PSC+1)*(ARR+1)) ))
carrier_ok=$([ "$FREQ" -ge 19800 ] && [ "$FREQ" -le 20200 ] && echo 1 || echo 0)
# read path: DMA destination + the io thread's CONSUMED cell (slot[rd] unless FRESH) vs g_adc_dma
M0AR_V=${P[2:0x4002001c]}; DMA_V=$(( ${P[2:$DMA_A]} & 0xFFFF ))
SHW=${P[2:$SH]}; SHARED=$(( SHW & 0xFF )); RD=$(( (SHW>>16)&0xFF )); FRESH=$(( (SHARED>>2)&1 ))
IDX=$([ "$FRESH" -eq 1 ] && echo $(( SHARED & 3 )) || echo $(( RD & 3 )))
case $IDX in 0) PUB=${P[2:$S0]};; 1) PUB=${P[2:$S1]};; 2) PUB=${P[2:$S2]};; *) PUB=999999;; esac
PUB=$(( PUB & 0xFFFF )); rd_diff=$(( PUB>DMA_V ? PUB-DMA_V : DMA_V-PUB ))

# NOTE: freshness-gated INIT hold (REQ-IO-021's init clause / REQ-IO-009) is NOT asserted
# here — this image's init duty is 0, which is also the ramp origin, so a boot-time read
# cannot distinguish "held init" from "first ramp step". That clause is covered by REQ-IO-009.
echo "== PWM (REQ-IO-021: carrier + duty->CCR) =="
ck "TIM1 counter enabled"    "$(( CR1 & 1 ))"           "CR1=$(printf 0x%X $CR1)"
ck "TIM1 MOE (output on)"    "$(( (BDTR>>15) & 1 ))"    "BDTR=$(printf 0x%X $BDTR)"
ck "TIM1_CH1 output (CC1E)"  "$(( CCER & 1 ))"          "CCER=$(printf 0x%X $CCER)"
ck "carrier ~20 kHz (derived)" "$carrier_ok"            "PSC=$PSC ARR=$ARR, tim_clk=$((tclk/1000000))MHz (SYSCLK ${GCPU_MHZ}MHz) -> ${FREQ} Hz"
ck "timer counting (UIF set)" "$(( SR & 1 ))"           "TIM1_SR=$(printf 0x%X $SR) after clear (timer wrapped)"
ck "duty ramp reaches CCR1"  "$ramp_moved"              "CCR1 $CCRa,$CCRb,$CCRc (FB->io->pwm_write)"

echo "== ADC (REQ-IO-018) =="
ck "ADC1 enabled (ADEN)"     "$(( ADCR & 1 ))"          "CR=$(printf 0x%X $ADCR)"
ck "ADC1 started (ADSTART)"  "$(( (ADCR>>2) & 1 ))"     "CR=$(printf 0x%X $ADCR)"
ck "DMA stream enabled"      "$(( S0CR & 1 ))"          "S0CR=$(printf 0x%X $S0CR)"
ck "DMA scan completing (TCIF)" "$(( (LISR>>5) & 1 ))"  "DMA1_LISR=$(printf 0x%X $LISR) after clear (a full scan landed)"
ck "DMA writes g_adc_dma"    "$([ "$M0AR_V" = "$((ADCDMA))" ] && echo 1||echo 0)" "M0AR=$(printf 0x%X $M0AR_V) == g_adc_dma $ADCDMA"
ck "io read tracks DMA (corrob.)" "$([ "$rd_diff" -le 256 ] && echo 1||echo 0)" "IOC[$IDX].pub=$PUB vs g_adc_dma=$DMA_V (|d|=$rd_diff; value logic host-tested)"

echo "== io thread liveness (sanity, not a REQ-IO-024 recovery proof) =="
ck "io serve loop advancing" "$([ "$IOX1" -gt "$IOX0" ] && echo 1||echo 0)" "g_io_exec_us $IOX0 -> $IOX1"

echo
if [ "$fails" = 0 ]; then echo "RESULT: PASS ($total/$total) — ADC + PWM verified on H755 silicon"; exit 0
else echo "RESULT: FAIL ($fails/$total failed) — regression on target"; exit 1; fi
