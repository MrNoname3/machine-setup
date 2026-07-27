#!/usr/bin/env bash
# Long-form validation of one voltage offset. The sweep proves a setting
# survives two 60-second runs, which is enough to rank candidates and not enough
# to trust one. This runs it far longer, watches the kernel log across the whole
# window rather than per run, and keeps the helper's watchdog fed.
#
#   ./validate.sh <offset_mv> [runs] [duration_ms]     e.g. ./validate.sh -100 4 300000
#
# Comparison is on fps, not on FurMark's score: the score scales with run
# length, so holding a 300 s score against a 60 s baseline yields a meaningless
# percentage.

set -uo pipefail
. "$(dirname "$0")/common.sh"

OFF="${1:?usage: validate.sh <offset_mv> [runs] [duration_ms]}"
RUNS="${2:-4}"
DUR_MS="${3:-300000}"

gt_require_helper || exit 1
D=$(gt_device) || exit 1
BASE_FPS=$(gt_baseline_fps) || exit 1

echo "== validating ${OFF} mV: ${RUNS} x $((DUR_MS/1000))s =="
START_TS=$(date '+%Y-%m-%d %H:%M:%S')

gt_cmd "voffset $OFF"
APPLIED=$(gt_offset_now "$D")
echo "   applied: ${APPLIED} mV"
[ "$APPLIED" = "$OFF" ] || { echo "   MISMATCH -- aborting" >&2; exit 1; }

# bench.sh sends no commands, so without this the watchdog would fire mid-run
# and revert the very setting under test.
gt_pinger_start
trap 'gt_pinger_stop; gt_cmd reset' EXIT INT TERM

LABEL="validate${OFF}"
FURMARK_EXTRA="--artifact-scanner" "$(dirname "$0")/bench.sh" "$LABEL" "$RUNS" "$DUR_MS"
BRC=$?
gt_pinger_stop

echo
echo "== checks over the whole window =="
KERN=$(gt_kernel_faults "$START_TS")
ART=$(gt_artifacts "$GT_RESULTS"/${LABEL}-run*.txt)

if [ -n "$KERN" ]; then echo "  KERNEL FAULT:"; echo "$KERN" | sed 's/^/    /'; else echo "  kernel    : clean"; fi
if [ -n "$ART" ];  then echo "  ARTIFACTS:";    echo "$ART"  | sed 's/^/    /'; else echo "  artifacts : none"; fi
echo "  benchmark : exit $BRC"

CSV=$(ls -t "$GT_LOGS"/${LABEL}-run${RUNS}-*.csv 2>/dev/null | head -1)
VDD=$(awk -F, '!/^[#t]/ && $11>=50 {v+=$4; n++} END {if(n) printf "%.0f", v/n; else print 0}' "$CSV" 2>/dev/null)
echo "  measured  : ${VDD} mV under load  <-- the only proof the offset is live"

awk -F'\t' -v b="$BASE_FPS" 'NR>1 && $11=="no" {f[++n]=$4; sum+=$4}
  END {
    if(!n){print "  performance: NO DATA"; exit}
    avg=sum/n
    for(i=1;i<=n;i++){d=f[i]-avg; ss+=d*d}
    printf "  performance: %.1f fps (%+.2f%% vs the %.1f fps baseline), spread %.2f%%\n",
           avg, 100*(avg-b)/b, b, 100*sqrt(ss/n)/avg
  }' "$GT_RESULTS/${LABEL}.tsv"

if [ -z "$KERN" ] && [ -z "$ART" ] && [ "$BRC" = 0 ]; then
  echo; echo "  --> ${OFF} mV PASSED"
else
  echo; echo "  --> ${OFF} mV FAILED -- do not commit this value"
fi
