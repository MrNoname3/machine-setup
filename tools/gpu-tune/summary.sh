#!/usr/bin/env bash
# Summarise sampler CSVs. Load-only: samples below the busy threshold are
# dropped, so menu and loading screens cannot drag the averages down and make a
# setting look more efficient than it is.
#
#   ./summary.sh [busy_threshold] <csv>...      # threshold default 50

set -euo pipefail

BUSY=50
case "${1:-}" in ''|*[!0-9]*) ;; *) BUSY="$1"; shift ;; esac
[ $# -gt 0 ] || { echo "usage: $0 [busy_threshold] <csv>..." >&2; exit 1; }

printf '%-30s %6s %7s %7s %7s %7s %6s %6s %6s %6s %6s\n' \
  FILE N SCLK_AVG SCLK_MAX PWR_AVG PWR_MAX VDD EDGE JUNC MEM FAN

for f in "$@"; do
  [ -r "$f" ] || { echo "skip (unreadable): $f" >&2; continue; }
  awk -F, -v busy="$BUSY" -v name="$(basename "$f")" '
    /^[#t]/ { next }
    $11 >= busy {
      n++; sclk += $2; pwr += $5; vdd += $4
      if ($2 > sclkmax) sclkmax = $2
      if ($5 > pwrmax)  pwrmax  = $5
      edge += $7; junc += $8; mem += $9; fan += $10
    }
    END {
      if (!n) { printf "%-30s %6s  (no samples above busy=%d%%)\n", name, 0, busy; exit }
      printf "%-30s %6d %7.0f %7.0f %7.1f %7.1f %6.0f %6.0f %6.0f %6.0f %6.0f\n",
             name, n, sclk/n, sclkmax, pwr/n, pwrmax, vdd/n, edge/n, junc/n, mem/n, fan/n
    }' "$f"
done
