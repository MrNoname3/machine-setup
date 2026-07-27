#!/usr/bin/env bash
# Fan sweep at a fixed offset and cap: how much temperature does noise buy?
#
#   ./fansweep.sh <offset_mv> <cap_w> [acoustic_rpm...]
#
# The knob is acoustic_target_rpm_threshold. The controller aims for
# fan_target_temperature but will not spin past the acoustic target to get
# there, which is why a card can sit above its own target under load.
#
# Runs are 120 s rather than 60 s: temperature, not score, is the measurement,
# and it needs time to settle.
#
# WARNING -- the trap this script exists to document: writing the reset/commit
# pair to anything under gpu_od/fan_ctrl SILENTLY drops an applied voltage
# offset, while pp_od_clk_voltage keeps reporting it as still set. The offset is
# therefore re-applied and re-verified at every point, and the measured voltage
# is recorded so a silent revert shows up in the results instead of masquerading
# as a fan effect.

set -uo pipefail
. "$(dirname "$0")/common.sh"

OFF="${1:?usage: fansweep.sh <offset_mv> <cap_w> [acoustic_rpm...]}"
CAP="${2:?usage: fansweep.sh <offset_mv> <cap_w> [acoustic_rpm...]}"
shift 2
RPMS=("$@"); [ ${#RPMS[@]} -eq 0 ] && RPMS=(1000 1400 1800 2200)

gt_require_helper || exit 1
D=$(gt_device) || exit 1
FANDIR="$D/gpu_od/fan_ctrl"
[ -d "$FANDIR" ] || { echo "no gpu_od/fan_ctrl -- is OverDrive active?" >&2; exit 1; }

RESULTS="$GT_RESULTS/fansweep-results.tsv"
gt_pinger_start
trap 'gt_pinger_stop; gt_cmd fan-reset; gt_cmd reset; echo "[$(date +%T)] restored to stock"' EXIT INT TERM

gt_cmd "cap $CAP"
echo "== fan sweep at ${OFF} mV / ${CAP} W =="
printf 'acoustic\tfps\tvddgfx\toffset_ok\tmem_max\tjunc_max\tfan_max\tpwr\n' > "$RESULTS"

for RPM in "${RPMS[@]}"; do
  echo; echo "[$(date +%T)] ---- acoustic target ${RPM} rpm ----"

  # Fan first, offset last -- see the warning at the top.
  gt_cmd fan-reset
  gt_cmd "fan-acoustic-target $RPM"
  gt_cmd "voffset $OFF"

  GOT_RPM=$(gt_fan_value "$FANDIR/acoustic_target_rpm_threshold")
  GOT_OFF=$(gt_offset_now "$D")
  OK=$([ "$GOT_OFF" = "$OFF" ] && echo yes || echo "NO($GOT_OFF)")
  echo "   acoustic=${GOT_RPM}  offset=${GOT_OFF} (ok=$OK)"
  [ "$GOT_RPM" = "$RPM" ] || { echo "   MISMATCH -- skipping"; continue; }

  LABEL="fan${RPM}"
  "$(dirname "$0")/bench.sh" "$LABEL" 2 120000 > "$GT_RESULTS/${LABEL}-bench.log" 2>&1

  read -r FPS MEM JUNC FANMAX PWR <<<"$(awk -F'\t' 'NR>1 && $11=="no" {
        f+=$4; p+=$6; n++; if($9>m)m=$9; if($8>j)j=$8; if($10>x)x=$10 }
      END { if(n) printf "%.1f %d %d %d %.1f", f/n, m, j, x, p/n; else print "0 0 0 0 0" }' \
      "$GT_RESULTS/${LABEL}.tsv" 2>/dev/null)"
  CSV=$(ls -t "$GT_LOGS"/${LABEL}-run2-*.csv 2>/dev/null | head -1)
  VDD=$(awk -F, '!/^[#t]/ && $11>=50 {v+=$4; n++} END {if(n) printf "%.0f", v/n; else print 0}' "$CSV" 2>/dev/null)

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$RPM" "$FPS" "${VDD:-0}" "$OK" "$MEM" "$JUNC" "$FANMAX" "$PWR" >> "$RESULTS"
  echo "   VRAM ${MEM}C  junction ${JUNC}C  fan ${FANMAX} rpm  ${FPS} fps  ${VDD} mV"
done

echo
echo "================ NOISE vs TEMPERATURE ================"
column -t "$RESULTS"
echo
awk -F'\t' 'NR==2 { bm=$5; bj=$6; bf=$7 }
  NR>2 { printf "  %s rpm target: VRAM %+d C, junction %+d C, fan %+d rpm vs the first point\n",
                $1, $5-bm, $6-bj, $7-bf }
  END { print ""
        print "  If VRAM does not move across the whole range, it is bound by the thermal"
        print "  path (pads, heatsink contact), not by airflow, and no fan setting reaches it." }' "$RESULTS"
