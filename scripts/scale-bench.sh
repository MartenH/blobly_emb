#!/usr/bin/env bash
# Run the `scale` example (the REAL generated stack) on vcan0..N-1 with CAN traffic
# and report the CPU load on each core. Partitions are threads pinned per core
# (core0 also hosts the bus bridges), so we sum each thread's CPU by its core.
#
#   (cd examples/scale && make all) && sudo make vcan && scripts/scale-bench.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EX="$ROOT/examples/scale"
BUSES="${BUSES:-8}"
SECS="${SECS:-5}"
HZ="$(getconf CLK_TCK)"

[ -x "$EX/bin/app" ] || { echo "build first: (cd examples/scale && make all)"; exit 1; }
for b in $(seq 0 $((BUSES - 1))); do
	ip link show "vcan$b" >/dev/null 2>&1 || { echo "vcan$b is down — run: sudo $ROOT/scripts/setup_vcan.sh"; exit 1; }
done

# Inject rx traffic on every bus (RxMsg id = 0x100 + bus) so the bridges decode.
gens=()
for b in $(seq 0 $((BUSES - 1))); do
	cangen "vcan$b" -I "$(printf '%X' $((0x100 + b)))" -L 8 -g 5 >/dev/null 2>&1 &
	gens+=($!)
done

"$EX/bin/app" >/dev/null 2>&1 &
app=$!
trap 'kill $app "${gens[@]}" 2>/dev/null || true' EXIT
sleep 1 # let threads pin + settle

# Per-thread CPU (utime+stime ticks) tagged with the thread's core (stat field 39),
# robust to a comm containing spaces/parens by cutting after the last ") ".
sample() {
	for d in /proc/$app/task/*/; do
		tid="$(basename "$d")"
		s="$(cat "$d/stat" 2>/dev/null)" || continue
		rest="${s##*) }"
		set -- $rest
		echo "$tid ${37} $((${12} + ${13}))"
	done
}

sample >/tmp/scale_before
sleep "$SECS"
sample >/tmp/scale_after

echo "scale example: ${BUSES} CAN buses on core0, 4 cores, 200 FBs — real generated stack"
echo "  (vcan traffic @5ms/bus, ${SECS}s sample)"
echo "  core  role              load"
awk -v hz="$HZ" -v secs="$SECS" '
	FNR==NR { b[$1]=$3; next }
	{ d=$3-b[$1]; if (d<0) d=0; core[$2]+=d }
	END {
		split("8 buses + 50 FBs:50 FBs         :50 FBs         :50 FBs         ", role, ":")
		for (c=0; c<=3; c++)
			printf "   %d    %s  %5.1f%%\n", c, role[c+1], (core[c]/hz)/secs*100
	}
' /tmp/scale_before /tmp/scale_after

# RAM: resident set of the whole process (V runtime + IOC region + thread stacks).
rss="$(awk '/VmRSS:/{print $2}' /proc/$app/status)"
hwm="$(awk '/VmHWM:/{print $2}' /proc/$app/status)"
threads="$(ls /proc/$app/task | wc -l)"
printf '  RAM:  VmRSS %d.%d MB  (peak %d.%d MB), %d threads\n' \
	$((rss / 1024)) $(((rss % 1024) * 10 / 1024)) $((hwm / 1024)) $(((hwm % 1024) * 10 / 1024)) "$threads"
