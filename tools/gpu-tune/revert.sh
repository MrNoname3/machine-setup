#!/usr/bin/env bash
# Undo everything a tuning SESSION can leave behind. Safe at any point,
# including when nothing has been changed -- each step is skipped if it does not
# apply.
#
#   sudo ./revert.sh            # revert the live settings
#   sudo ./revert.sh --karg     # also drop the kernel argument (needs a reboot)
#
# What is and is not persistent:
#   * every sysfs value below is VOLATILE -- a plain reboot already restores it.
#     This exists so you do not have to reboot to get back to stock.
#   * only the kernel argument survives, and it is inert on its own: it exposes
#     the OverDrive interface, it does not change any setting.
#
# This does NOT touch the graphics role's permanent installation
# (/usr/local/bin/amdgpu-tune and its units) -- see that role's README to
# remove those.

set -uo pipefail

KARG_KEY=amdgpu.ppfeaturemask
WANT_KARG=0
for a in "$@"; do
  case "$a" in
    --karg) WANT_KARG=1 ;;
    *) echo "unknown option: $a (only --karg)" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }

D=""
for d in /sys/class/drm/card*/device; do
  [ -r "$d/uevent" ] || continue
  grep -qx 'DRIVER=amdgpu' "$d/uevent" 2>/dev/null && { D=$d; break; }
done
[ -n "$D" ] || { echo "no amdgpu device found" >&2; exit 1; }

H=""
for h in "$D"/hwmon/hwmon*; do
  [ -r "$h/name" ] && [ "$(cat "$h/name")" = amdgpu ] && { H=$h; break; }
done

say() { printf '  %-42s %s\n' "$1" "$2"; }

echo "== reverting live GPU settings =="

if [ -n "$H" ] && [ -w "$H/power1_cap" ]; then
  DEF=$(cat "$H/power1_cap_default"); CUR=$(cat "$H/power1_cap")
  if [ "$CUR" != "$DEF" ]; then
    echo "$DEF" > "$H/power1_cap" && say "power limit" "$((CUR/1000000))W -> $((DEF/1000000))W"
  else
    say "power limit" "already stock ($((DEF/1000000))W)"
  fi
fi

if [ -w "$D/pp_od_clk_voltage" ]; then
  echo r > "$D/pp_od_clk_voltage" 2>/dev/null
  echo c > "$D/pp_od_clk_voltage" 2>/dev/null && say "OverDrive table" "reset to defaults"
else
  say "OverDrive table" "not present -- nothing to do"
fi

if [ -d "$D/gpu_od/fan_ctrl" ]; then
  for f in "$D"/gpu_od/fan_ctrl/*; do [ -w "$f" ] && echo r > "$f" 2>/dev/null; done
  say "fan curve" "reset to defaults"
fi

[ -w "$D/power_dpm_force_performance_level" ] && {
  echo auto > "$D/power_dpm_force_performance_level" && say "performance level" "auto"; }

# Stop the session helper if one is up; it resets the GPU on its way out.
if [ -p /run/amdgpu-tune-session.fifo ]; then
  echo stop > /run/amdgpu-tune-session.fifo 2>/dev/null
  say "session helper" "stop sent"
else
  say "session helper" "not running -- nothing to do"
fi

if [ "$WANT_KARG" = 1 ]; then
  echo
  echo "== reverting the kernel argument =="
  MASK=$(grep -o "${KARG_KEY}=[0-9a-fx]*" /proc/cmdline | head -1)
  if [ -n "$MASK" ]; then
    rpm-ostree kargs --delete-if-present="$MASK" --unchanged-exit-77
    case $? in
      0)  say "$MASK" "removed -- REBOOT to apply" ;;
      77) say "$MASK" "was not set -- nothing to do" ;;
      *)  say "$MASK" "rpm-ostree reported an error" ;;
    esac
  else
    say "$KARG_KEY" "not on the cmdline -- nothing to do"
  fi
elif grep -q "$KARG_KEY" /proc/cmdline; then
  echo
  echo "  note: the kernel argument is still set (harmless on its own)."
  echo "        run with --karg to remove it too."
fi

echo
echo "done. Current state:"
[ -n "$H" ] && echo "  power cap : $(( $(cat "$H/power1_cap") / 1000000 ))W (stock $(( $(cat "$H/power1_cap_default") / 1000000 ))W)"
echo "  perf level: $(cat "$D/power_dpm_force_performance_level" 2>/dev/null)"
echo "  ppfeatmask: $(cat /sys/module/amdgpu/parameters/ppfeaturemask)"
echo "  OverDrive : $([ -e "$D/pp_od_clk_voltage" ] && echo exposed || echo "not exposed")"
