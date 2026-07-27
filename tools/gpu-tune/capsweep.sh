#!/usr/bin/env bash
# Power-cap sweep at a fixed voltage offset. Answers what the undervolt result
# leaves open: the headroom can be spent on speed OR traded back for less power
# and heat, and this measures the exchange rate instead of guessing it.
#
#   ./capsweep.sh <offset_mv> [cap_w...]      e.g. ./capsweep.sh -100 300 280 260 240
#
# The number to look for is the lowest cap that still matches the untuned
# baseline. Everything above that line is free cooling: less power and lower
# temperatures at no cost in performance compared to a stock card.

set -uo pipefail
. "$(dirname "$0")/common.sh"

OFF="${1:?usage: capsweep.sh <offset_mv> [cap_w...]}"; shift
CAPS=("$@")

gt_require_helper || exit 1
gt_require_furmark || exit 1
D=$(gt_device) || exit 1
H=$(gt_hwmon "$D") || exit 1
BASE_FPS=$(gt_baseline_fps) || exit 1

if [ ${#CAPS[@]} -eq 0 ]; then
  CMIN=$(( $(cat "$H/power1_cap_min") / 1000000 ))
  CMAX=$(( $(cat "$H/power1_cap_default") / 1000000 ))
  # five points between the driver's floor and the stock cap
  for i in 1 2 3 4 5; do CAPS+=( $(( CMAX - (CMAX-CMIN)*i/5 )) ); done
  echo "no caps given -- using the driver's range: ${CAPS[*]}"
fi

RESULTS="$GT_RESULTS/capsweep-results.tsv"
gt_pinger_start
trap 'gt_pinger_stop; gt_cmd reset; echo "[$(date +%T)] restored to stock"' EXIT INT TERM

gt_cmd "voffset $OFF"
APPLIED=$(gt_offset_now "$D")
[ "$APPLIED" = "$OFF" ] || { echo "offset did not apply ($APPLIED)" >&2; exit 1; }

echo "== power cap sweep at ${OFF} mV =="
echo "   baseline (stock, 0 mV): ${BASE_FPS} fps"
printf 'cap_w\tfps\tvs_base\tvddgfx\tpwr_meas\tsclk\tjunc\tmem\tfan\n' > "$RESULTS"

for CAP in "${CAPS[@]}"; do
  echo; echo "[$(date +%T)] ---- power cap ${CAP} W ----"
  gt_cmd "cap $CAP"
  REAL=$(( $(cat "$H/power1_cap") / 1000000 ))
  echo "   sysfs reports: ${REAL} W"
  [ "$REAL" = "$CAP" ] || { echo "   MISMATCH -- skipping"; continue; }

  LABEL="cap${CAP}"
  "$(dirname "$0")/bench.sh" "$LABEL" 2 60000 > "$GT_RESULTS/${LABEL}-bench.log" 2>&1

  read -r FPS PWR SCLK JUNC MEM FAN <<<"$(awk -F'\t' 'NR>1 && $11=="no" {
        f+=$4; p+=$6; c+=$7; n++; if($8>j)j=$8; if($9>m)m=$9; if($10>x)x=$10 }
      END { if(n) printf "%.1f %.1f %.0f %d %d %d", f/n, p/n, c/n, j, m, x; else print "0 0 0 0 0 0" }' \
      "$GT_RESULTS/${LABEL}.tsv" 2>/dev/null)"
  CSV=$(ls -t "$GT_LOGS"/${LABEL}-run2-*.csv 2>/dev/null | head -1)
  VDD=$(awk -F, '!/^[#t]/ && $11>=50 {v+=$4; n++} END {if(n) printf "%.0f", v/n; else print 0}' "$CSV" 2>/dev/null)

  VS=$(awk -v f="$FPS" -v b="$BASE_FPS" 'BEGIN{printf "%+.2f", 100*(f-b)/b}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$CAP" "$FPS" "$VS" "${VDD:-0}" "$PWR" "$SCLK" "$JUNC" "$MEM" "$FAN" >> "$RESULTS"
  echo "   ${FPS} fps (${VS}% vs baseline)  ${VDD} mV  ${PWR}W  junction ${JUNC}C  mem ${MEM}C  fan ${FAN}"
done

echo
echo "================ EXCHANGE RATE ================"
column -t "$RESULTS"
echo
awk -F'\t' -v b="$BASE_FPS" 'NR>1 && $2+0 >= b { best=$1; bf=$2; bj=$7; bm=$8; bfan=$9 }
  END {
    if (best=="") { print "  Every measured cap falls below the baseline."; exit }
    printf "  Lowest cap that still matches the untuned card: %s W\n", best
    printf "    %.1f fps, junction %sC, mem %sC, fan %s rpm\n", bf, bj, bm, bfan
  }' "$RESULTS"
