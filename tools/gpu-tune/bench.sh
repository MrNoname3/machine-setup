#!/usr/bin/env bash
# The measurement primitive everything else builds on: run the FurMark Vulkan
# benchmark N times under identical conditions, capture the score and the sysfs
# telemetry for each run, and report the spread.
#
#   ./bench.sh <label> [runs] [duration_ms]
#   FURMARK_EXTRA="--artifact-scanner" ./bench.sh <label> ...
#
# Reproducibility is the whole point, so:
#   * the title bar is off -- with it on the window is 1920x1008, not 1920x1080,
#     and a different pixel count is a different benchmark;
#   * every run is preceded by a cooldown to a fixed junction temperature, so a
#     run never starts on a hotter card than the one it is compared against;
#   * the first run is marked warm-up and excluded from the spread.
#
# NOTE: the score is proportional to run length (60 s -> ~24k, 300 s -> ~120k).
# Only compare scores between runs of the same duration; fps is what carries
# across.

set -uo pipefail
. "$(dirname "$0")/common.sh"

LABEL="${1:?usage: bench.sh <label> [runs] [duration_ms]}"
RUNS="${2:-3}"
DUR_MS="${3:-60000}"

COOL_TO_C="${GT_COOL_TO_C:-50}"
COOL_MAX_S="${GT_COOL_MAX_S:-240}"
read -r -a EXTRA <<<"${FURMARK_EXTRA:-}"

gt_require_furmark || exit 1
D=$(gt_device) || exit 1
H=$(gt_hwmon "$D") || exit 1

junction() { echo $(( $(cat "$H/temp2_input") / 1000 )); }

cooldown() {
  local t0 j; t0=$(date +%s)
  while :; do
    j=$(junction)
    [ "$j" -le "$COOL_TO_C" ] && { echo "    cooled to ${j}C"; return; }
    [ $(( $(date +%s) - t0 )) -ge "$COOL_MAX_S" ] && {
      echo "    cooldown timed out at ${COOL_MAX_S}s, junction=${j}C"; return; }
    sleep 5
  done
}

TSV="$GT_RESULTS/${LABEL}.tsv"
printf 'run\tscore\tfps_min\tfps_avg\tfps_max\tpwr_avg_w\tsclk_avg\tjunc_max\tmem_max\tfan_max\twarmup\n' > "$TSV"

echo "== bench '$LABEL': $RUNS x $((DUR_MS/1000))s =="

for i in $(seq 1 "$RUNS"); do
  echo "  [$(date +%T)] run $i/$RUNS"
  echo "    cooling to ${COOL_TO_C}C..."
  cooldown

  "$(dirname "$0")/sample.sh" "${LABEL}-run${i}" $(( DUR_MS/1000 + 20 )) >/dev/null 2>&1 &
  SP=$!
  sleep 3

  OUT="$GT_RESULTS/${LABEL}-run${i}.txt"
  timeout $(( DUR_MS/1000 + 90 )) "${GT_FURMARK[@]}" \
    --demo "$GT_DEMO" \
    --width 1920 --height 1080 --title-bar 0 \
    --benchmark --duration-ms "$DUR_MS" \
    --no-score-box --disable-demo-options \
    --vsync 0 --no-gpumon \
    "${EXTRA[@]}" \
    > "$OUT" 2>&1
  RC=$?
  wait $SP 2>/dev/null

  # FurMark's stdout carries stray control bytes; force text mode when parsing.
  SCORE=$(grep -a 'SCORE' "$OUT" | grep -oE '[0-9]+' | tail -1)
  FPS=$(grep -a 'FPS (min/avg/max)' "$OUT" | grep -oE '[0-9]+ / [0-9]+ / [0-9]+')
  FMIN=$(echo "$FPS" | cut -d' ' -f1); FAVG=$(echo "$FPS" | cut -d' ' -f3); FMAX=$(echo "$FPS" | cut -d' ' -f5)

  CSV=$(ls -t "$GT_LOGS"/${LABEL}-run${i}-*.csv 2>/dev/null | head -1)
  read -r PWR SCLK JMAX MMAX FANMAX <<<"$(awk -F, '!/^[#t]/ && $11>=50 {
        p+=$5; s+=$2; n++; if($8>j)j=$8; if($9>m)m=$9; if($10>f)f=$10 }
      END { if(n) printf "%.1f %.0f %d %d %d", p/n, s/n, j, m, f; else print "0 0 0 0 0" }' "$CSV")"

  WARM=$([ "$i" = 1 ] && echo yes || echo no)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$i" "${SCORE:-ERR}" "${FMIN:-0}" "${FAVG:-0}" "${FMAX:-0}" \
    "$PWR" "$SCLK" "$JMAX" "$MMAX" "$FANMAX" "$WARM" >> "$TSV"

  echo "    score=${SCORE:-ERR}  fps=${FAVG:-?}  ${PWR}W  junction ${JMAX}C  mem ${MMAX}C  (exit $RC)"
done

echo
echo "== '$LABEL' summary =="
column -t "$TSV"
echo
awk -F'\t' 'NR>1 && $11=="no" { s[++n]=$2; sum+=$2; f+=$4 }
  END {
    if (n<2) { print "  (spread needs 2+ non-warm-up runs)"; exit }
    avg=sum/n
    for (i=1;i<=n;i++) { d=s[i]-avg; ss+=d*d; if(s[i]>mx||mx==0)mx=s[i]; if(s[i]<mn||mn==0)mn=s[i] }
    printf "  mean score : %.0f   mean fps: %.1f   (n=%d, warm-up excluded)\n", avg, f/n, n
    printf "  std dev    : %.1f = %.2f%%\n", sqrt(ss/n), 100*sqrt(ss/n)/avg
    printf "  min-max    : %d - %d = %.2f%% range\n", mn, mx, 100*(mx-mn)/avg
    printf "  --> a change smaller than this cannot be resolved at this sample size\n"
  }' "$TSV"
