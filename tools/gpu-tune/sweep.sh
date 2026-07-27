#!/usr/bin/env bash
# Unattended undervolt sweep: walk the GFX voltage offset down in steps until
# the card shows the first sign of trouble, then stop and report.
#
#   ./sweep.sh [step_mv] [floor_mv] [runs_per_point]
#     step_mv   default 20   (magnitude; the sweep always goes negative)
#     floor_mv  default -200 (clamped to whatever the driver actually allows)
#
# Instability is looked for three independent ways, because an undervolt fails
# in three different ways and only one of them is loud:
#   1. FurMark's artifact scanner  -- visual corruption, the earliest signal;
#   2. the kernel log              -- GPU resets, ring timeouts, VM faults;
#   3. the benchmark itself        -- a crash, a missing score, or a score that
#                                     falls off a cliff instead of improving.
# Any one of them ends the sweep. The helper resets the GPU on exit no matter
# how this script terminates.
#
# READ THE RESULT, DO NOT JUST TAKE THE LAST STABLE VALUE. If the clock stops
# rising before the failure point, the offsets past that gain nothing and cost
# margin -- pick the knee. See README.md.

set -uo pipefail
. "$(dirname "$0")/common.sh"

STEP="${1:-20}"
FLOOR="${2:--200}"
RUNS="${3:-2}"

gt_require_helper || exit 1
gt_require_furmark || exit 1
D=$(gt_device) || exit 1
[ -e "$D/pp_od_clk_voltage" ] || {
  echo "OverDrive is not exposed -- was there a reboot after the kernel argument?" >&2
  echo "  cmdline: $(grep -o 'ppfeaturemask=[0-9a-fx]*' /proc/cmdline || echo none)" >&2
  exit 1; }

BASE_FPS=$(gt_baseline_fps) || exit 1
RESULTS="$GT_RESULTS/sweep-results.tsv"

gt_pinger_start
finish() {
  gt_pinger_stop
  echo; echo "[$(date +%T)] restoring stock"
  gt_cmd reset
  echo "[$(date +%T)] helper still up; stop it with: echo stop > $GT_FIFO"
}
trap finish EXIT INT TERM

# The driver's advertised limit wins over the requested floor.
DRV=$(gt_offset_range "$D" | awk '{print $1}')
if [[ "$DRV" =~ ^-?[0-9]+$ ]] && [ "$DRV" -gt "$FLOOR" ]; then
  echo "driver floor ($DRV mV) is tighter than requested ($FLOOR mV) -- using the driver's"
  FLOOR="$DRV"
fi

echo "== undervolt sweep: 0 -> $FLOOR mV in ${STEP}mV steps, $RUNS runs/point =="
echo "   baseline: ${BASE_FPS} fps"
printf 'offset_mv\tfps\tdelta_pct\tvddgfx\tpwr_w\tsclk\tjunc\tmem\tverdict\n' > "$RESULTS"

LAST_STABLE=0
OFF=0
while :; do
  OFF=$(( OFF - STEP ))
  [ "$OFF" -lt "$FLOOR" ] && { echo "[$(date +%T)] reached the floor ($FLOOR mV)"; break; }

  echo; echo "[$(date +%T)] ---- offset ${OFF} mV ----"
  SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  gt_cmd "voffset $OFF"

  APPLIED=$(gt_offset_now "$D")
  echo "   sysfs reports: ${APPLIED:-?} mV"
  if [ -n "$APPLIED" ] && [ "$APPLIED" != "$OFF" ]; then
    echo "   MISMATCH: asked $OFF, got $APPLIED -- stopping"
    printf '%s\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$OFF" "not_applicable" >> "$RESULTS"
    break
  fi

  LABEL="uv${OFF}"
  FURMARK_EXTRA="--artifact-scanner" "$(dirname "$0")/bench.sh" "$LABEL" "$RUNS" 60000 \
    > "$GT_RESULTS/${LABEL}-bench.log" 2>&1
  BRC=$?

  VERDICT=stable
  ART=$(gt_artifacts "$GT_RESULTS"/${LABEL}-run*.txt | head -3)
  [ -n "$ART" ] && VERDICT=ARTIFACTS
  KERN=$(gt_kernel_faults "$SINCE" | head -3)
  [ -n "$KERN" ] && VERDICT=KERNEL_FAULT

  read -r FPS PWR SCLK JUNC MEM <<<"$(awk -F'\t' 'NR>1 && $11=="no" {
        f+=$4; p+=$6; c+=$7; n++; if($8>j)j=$8; if($9>m)m=$9 }
      END { if(n) printf "%.1f %.1f %.0f %d %d", f/n, p/n, c/n, j, m; else print "0 0 0 0 0" }' \
      "$GT_RESULTS/${LABEL}.tsv" 2>/dev/null)"
  CSV=$(ls -t "$GT_LOGS"/${LABEL}-run${RUNS}-*.csv 2>/dev/null | head -1)
  VDD=$(awk -F, '!/^[#t]/ && $11>=50 {v+=$4; n++} END {if(n) printf "%.0f", v/n; else print 0}' "$CSV" 2>/dev/null)

  { [ "$BRC" != 0 ] || [ -z "$FPS" ] || [ "$FPS" = "0.0" ]; } && VERDICT=BENCHMARK_FAILED

  DELTA=$(awk -v f="$FPS" -v b="$BASE_FPS" 'BEGIN{printf "%+.2f", 100*(f-b)/b}')
  awk -v f="$FPS" -v b="$BASE_FPS" 'BEGIN{exit !(f < b*0.95)}' && [ "$VERDICT" = stable ] \
    && VERDICT=PERFORMANCE_COLLAPSE

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$OFF" "$FPS" "$DELTA" "${VDD:-0}" "$PWR" "$SCLK" "$JUNC" "$MEM" "$VERDICT" >> "$RESULTS"
  echo "   ${FPS} fps (${DELTA}%)  ${VDD} mV  ${SCLK} MHz  ${PWR}W  junction ${JUNC}C  -> $VERDICT"

  if [ "$VERDICT" != stable ]; then
    [ -n "$ART" ]  && { echo "   artifacts:"; echo "$ART" | sed 's/^/     /'; }
    [ -n "$KERN" ] && { echo "   kernel:";    echo "$KERN" | sed 's/^/     /'; }
    echo "[$(date +%T)] instability at ${OFF} mV -- sweep ends"
    break
  fi
  LAST_STABLE=$OFF
done

echo
echo "================ RESULT ================"
column -t "$RESULTS"
echo
echo "  last stable offset: ${LAST_STABLE} mV"
if [ "$LAST_STABLE" -lt 0 ]; then
  awk -F'\t' 'NR>1 && $9=="stable" { if (prev != "") d=$6-prev; prev=$6;
      printf "  %5s mV: %s MHz%s\n", $1, $6, (d=="" ? "" : sprintf("  (%+d)", d)) }' "$RESULTS"
  cat <<'EOF'

  Pick the KNEE, not the last stable value: where the clock stops climbing,
  further offset buys nothing and only shortens the margin to the failure
  point. Then validate the choice properly:

    ./validate.sh <chosen_mv> 4 300000
EOF
else
  echo "  No negative offset proved stable -- this chip has no headroom; stay stock."
fi
