#!/usr/bin/env bash
# GPU telemetry sampler -- READ-ONLY, needs no privileges.
#
#   ./sample.sh <label> [seconds]     # seconds omitted = until Ctrl-C
#
# Writes one CSV row per sample to $GT_LOGS/<label>-<timestamp>.csv. Runs
# alongside any workload; every other script here uses it.

set -euo pipefail
. "$(dirname "$0")/common.sh"

LABEL="${1:-run}"
DURATION="${2:-0}"
INTERVAL="${GT_SAMPLE_INTERVAL:-0.5}"

D=$(gt_device) || exit 1
H=$(gt_hwmon "$D") || exit 1
OUT="$GT_LOGS/${LABEL}-$(date +%Y%m%d-%H%M%S).csv"

r() { cat "$1" 2>/dev/null || echo 0; }
mhz()  { echo "$(( $(r "$1") / 1000000 ))"; }
mdeg() { echo "$(( $(r "$1") / 1000 ))"; }
watt() { awk -v v="$(r "$1")" 'BEGIN{printf "%.1f", v/1000000}'; }
lbl()  { cat "$H/$1" 2>/dev/null || echo "?"; }

START=$(date +%s.%N)
{
  echo "# gpu=$(r "$D/vbios_version") cap_default_W=$(watt "$H/power1_cap_default")"
  echo "# temp1=$(lbl temp1_label) temp2=$(lbl temp2_label) temp3=$(lbl temp3_label)"
  echo "# ppfeaturemask=$(r /sys/module/amdgpu/parameters/ppfeaturemask)"
  echo "# perf_level=$(r "$D/power_dpm_force_performance_level") offset=$(gt_offset_now "$D")"
  # start_epoch maps a row back to wall clock (t_s + start_epoch), which is how a
  # run gets lined up against a MangoHud log covering the same window.
  echo "# start_epoch=$START start_local=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "t_s,sclk_mhz,mclk_mhz,vddgfx_mv,power_w,cap_w,edge_c,junction_c,mem_c,fan_rpm,busy_pct"
} > "$OUT"

echo "logging -> $OUT   (Ctrl-C to stop)" >&2

while :; do
  T=$(awk -v a="$(date +%s.%N)" -v b="$START" 'BEGIN{printf "%.1f", a-b}')
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$T" "$(mhz "$H/freq1_input")" "$(mhz "$H/freq2_input")" "$(r "$H/in0_input")" \
    "$(watt "$H/power1_average")" "$(watt "$H/power1_cap")" \
    "$(mdeg "$H/temp1_input")" "$(mdeg "$H/temp2_input")" "$(mdeg "$H/temp3_input")" \
    "$(r "$H/fan1_input")" "$(r "$D/gpu_busy_percent")" >> "$OUT"

  if [ "$DURATION" != "0" ]; then
    awk -v t="$T" -v d="$DURATION" 'BEGIN{exit !(t>=d)}' && break
  fi
  sleep "$INTERVAL"
done

echo "done: $OUT ($(grep -cvE '^[#t]' "$OUT") samples)" >&2
