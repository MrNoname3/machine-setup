#!/bin/sh
# Usage: resource-top.sh mem [N] | cpu [SECONDS] [N]
#   mem  proportional memory (PSS) per process name, summed over its processes
#   cpu  CPU time per process name over SECONDS (default 60), as a share of one core
# Prints the top N (default 25). Run as root to include other users' processes.
set -e
mode=${1:-mem}

case $mode in
mem)
  top=${2:-25}
  for p in /proc/[0-9]*; do
    pss=$(awk '/^Pss:/ { print $2 }' "$p/smaps_rollup" 2>/dev/null) || continue
    [ -n "$pss" ] && printf '%s %s\n' "$pss" "$(cat "$p/comm" 2>/dev/null)"
  done | awk '{ k = $2; for (i = 3; i <= NF; i++) k = k " " $i; s[k] += $1; n[k]++ }
    END { for (k in s) printf "%7.0f MB %3d  %s\n", s[k] / 1024, n[k], k }' |
    sort -rn | head -n "$top"
  echo
  free -m
  ;;
cpu)
  secs=${2:-60}
  top=${3:-25}
  # pid, utime + stime in clock ticks, name; the name may contain spaces.
  snap() {
    for p in /proc/[0-9]*; do
      read -r line < "$p/stat" 2>/dev/null || continue
      comm=${line#*(}; comm=${comm%)*}
      # shellcheck disable=SC2086  # split the fields after the name
      set -- ${line##*) }
      echo "${p#/proc/} $((${12} + ${13})) $comm"
    done
  }
  before=$(snap)
  sleep "$secs"
  after=$(snap)
  printf '%s\n--\n%s\n' "$before" "$after" |
    awk -v hz="$(getconf CLK_TCK)" -v s="$secs" '
      $0 == "--" { second = 1; next }
      !second { a[$1] = $2; next }
      ($1 in a) { name = $3; for (i = 4; i <= NF; i++) name = name " " $i; d[name] += $2 - a[$1] }
      END { for (n in d) if (d[n] > 0) printf "%6.2f%%  %s\n", 100 * d[n] / hz / s, n }' |
    sort -rn | head -n "$top"
  ;;
*)
  echo "usage: resource-top.sh mem [N] | cpu [SECONDS] [N]" >&2
  exit 2
  ;;
esac
