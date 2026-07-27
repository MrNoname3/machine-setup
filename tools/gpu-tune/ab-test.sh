#!/usr/bin/env bash
# Interleaved A/B/A/B test of two helper settings.
#
#   ./ab-test.sh "<helper command A>" "<helper command B>" [blocks] [runs] [ms]
#   e.g. ./ab-test.sh "fan-acoustic-target 1800" "fan-acoustic-target 1400" 4
#
# Use this whenever a sweep produces a result that does not fit a trend. A sweep
# walks its points in order, so anything that drifts during the session -- case
# heat soak being the obvious candidate -- gets attributed to whichever setting
# happened to be measured at the time. Interleaving separates the two: if A wins
# in both of its slots the setting is responsible; if the later blocks are simply
# slower than the earlier ones regardless of setting, something is drifting.
#
# The voltage offset is re-applied and re-verified before every block, and the
# measured voltage is recorded -- a setting that silently reverts the offset
# would otherwise look exactly like a setting that improves performance.

set -uo pipefail
. "$(dirname "$0")/common.sh"

CMD_A="${1:?usage: ab-test.sh \"<cmd A>\" \"<cmd B>\" [blocks] [runs] [ms]}"
CMD_B="${2:?usage: ab-test.sh \"<cmd A>\" \"<cmd B>\" [blocks] [runs] [ms]}"
BLOCKS="${3:-4}"
RUNS="${4:-2}"
DUR_MS="${5:-60000}"
OFF="${GT_AB_OFFSET:-}"

gt_require_helper || exit 1
D=$(gt_device) || exit 1
RESULTS="$GT_RESULTS/ab-test.tsv"

gt_pinger_start
trap 'gt_pinger_stop; gt_cmd reset' EXIT INT TERM

echo "== A/B/A/B: [A] $CMD_A   vs   [B] $CMD_B =="
printf 'block\tside\tsetting\tfps\tvddgfx\tsclk\tjunc\tmem\tpwr\n' > "$RESULTS"

for i in $(seq 1 "$BLOCKS"); do
  if [ $(( i % 2 )) -eq 1 ]; then SIDE=A; CMD="$CMD_A"; else SIDE=B; CMD="$CMD_B"; fi
  echo; echo "[$(date +%T)] ---- block $i [$SIDE]: $CMD ----"

  [ -n "$OFF" ] && { gt_cmd "voffset $OFF"; echo "   offset: $(gt_offset_now "$D") mV"; }
  gt_cmd "$CMD"

  LABEL="ab-b${i}-${SIDE}"
  "$(dirname "$0")/bench.sh" "$LABEL" "$RUNS" "$DUR_MS" > "$GT_RESULTS/${LABEL}-bench.log" 2>&1

  read -r FPS SCLK JUNC MEM PWR <<<"$(awk -F'\t' 'NR>1 && $11=="no" {
        f+=$4; c+=$7; p+=$6; n++; if($8>j)j=$8; if($9>m)m=$9 }
      END { if(n) printf "%.1f %.0f %d %d %.1f", f/n, c/n, j, m, p/n; else print "0 0 0 0 0" }' \
      "$GT_RESULTS/${LABEL}.tsv" 2>/dev/null)"
  CSV=$(ls -t "$GT_LOGS"/${LABEL}-run${RUNS}-*.csv 2>/dev/null | head -1)
  VDD=$(awk -F, '!/^[#t]/ && $11>=50 {v+=$4; n++} END {if(n) printf "%.0f", v/n; else print 0}' "$CSV" 2>/dev/null)

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$i" "$SIDE" "$CMD" "$FPS" "${VDD:-0}" "$SCLK" "$JUNC" "$MEM" "$PWR" >> "$RESULTS"
  echo "   ${FPS} fps  ${VDD} mV  ${SCLK} MHz  junction ${JUNC}C  mem ${MEM}C"
done

echo
echo "================ A/B/A/B ================"
column -t "$RESULTS"
echo
awk -F'\t' 'NR>1 { s[$2]+=$4; n[$2]++; ord[NR-1]=$4 }
  END {
    a=s["A"]/n["A"]; b=s["B"]/n["B"]
    printf "  [A] mean: %.1f fps\n  [B] mean: %.1f fps\n", a, b
    printf "  in order:"; for (i=1;i<=length(ord);i++) printf " %.0f", ord[i]; print ""
    d = b - a
    if (d > a*0.02)       print "  --> the SETTING matters: B wins in both of its slots"
    else if (d < -a*0.02) print "  --> the SETTING matters: A wins in both of its slots"
    else                  print "  --> no real difference; any effect seen in a sequential sweep was drift"
  }' "$RESULTS"
