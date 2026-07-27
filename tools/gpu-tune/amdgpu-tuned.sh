#!/usr/bin/env bash
# Privileged helper for a tuning session. Started ONCE with a graphical password
# prompt; from then on it takes commands over a pipe, so a sweep of dozens of
# settings needs no further authentication.
#
#   SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./amdgpu-tuned.sh &
#
# Deliberately self-contained: it does not source common.sh. A process running
# as root should not pull code out of a file that an unprivileged user can edit,
# even the user's own checkout.
#
# It is not a general-purpose root shell:
#   * it accepts a fixed list of verbs and nothing else;
#   * every numeric argument is checked against a hard range, and the OverDrive
#     knobs additionally against the range the driver itself reports;
#   * it resets the GPU to stock on ANY exit -- normal stop, signal, or crash;
#   * a watchdog resets and exits after WATCHDOG_S of silence, so a dead session
#     or a hung machine cannot leave a tuned value applied.
#
# Nothing is installed anywhere: no sudoers file, no unit, no persistent
# privilege. When this process exits, the grant is gone with it. This is the
# session tool -- the permanent mechanism is the graphics role's amdgpu-tune.

set -uo pipefail

FIFO=/run/amdgpu-tune-session.fifo
STATUS=/run/amdgpu-tune-session.status
LOG=/run/amdgpu-tune-session.log
WATCHDOG_S="${WATCHDOG_S:-900}"
OWNER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

# Hard limits, independent of whatever the driver claims to allow.
CAP_MIN_W=100
CAP_MAX_W=1000
VOFF_MIN_MV=-250
VOFF_MAX_MV=0

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

D=""
if [ -n "${GPU_PCI:-}" ]; then
  D="/sys/bus/pci/devices/$GPU_PCI"
else
  for d in /sys/class/drm/card*/device; do
    [ -r "$d/uevent" ] || continue
    grep -qx 'DRIVER=amdgpu' "$d/uevent" 2>/dev/null && { D=$d; break; }
  done
fi
[ -n "$D" ] && [ -d "$D" ] || { echo "no amdgpu device found" >&2; exit 1; }

H=""
for h in "$D"/hwmon/hwmon*; do
  [ -r "$h/name" ] && [ "$(cat "$h/name")" = amdgpu ] && { H=$h; break; }
done
[ -n "$H" ] || { echo "no amdgpu hwmon" >&2; exit 1; }

FAN="$D/gpu_od/fan_ctrl"
OD="$D/pp_od_clk_voltage"

log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$LOG" >&2; }

# ---- stock restore, the one thing that must never fail -------------------
reset_all() {
  local def
  def=$(cat "$H/power1_cap_default" 2>/dev/null) && [ -n "$def" ] \
    && echo "$def" > "$H/power1_cap" 2>/dev/null
  if [ -w "$OD" ]; then
    echo r > "$OD" 2>/dev/null; echo c > "$OD" 2>/dev/null
  fi
  if [ -d "$FAN" ]; then
    for f in "$FAN"/*; do [ -w "$f" ] && echo r > "$f" 2>/dev/null; done
  fi
  echo auto > "$D/power_dpm_force_performance_level" 2>/dev/null
  log "GPU reset to stock"
}

cleanup() { reset_all; rm -f "$FIFO"; log "helper exit -- privilege released"; }
trap cleanup EXIT
trap 'exit 0' TERM INT HUP

is_int() { case "$1" in ''|*[!0-9-]*) return 1 ;; *) return 0 ;; esac; }

od_range_voff() {
  [ -r "$OD" ] || return 1
  awk '/VDDGFX_OFFSET/ && NF>=3 {gsub(/[mM][vV]/,"",$2); gsub(/[mM][vV]/,"",$3); print $2, $3; exit}' "$OD"
}

# gpu_od/fan_ctrl files put the label on line 1 and the value on line 2.
fan_value() { awk 'NR==2{print $1}' "$FAN/$1" 2>/dev/null; }

# Each knob takes the same two-step write: the value, then a commit. Without the
# commit the driver keeps the old setting and reports nothing.
fan_set() {
  local file="$1" val="$2" lo="$3" hi="$4" name="$5"
  is_int "$val" || { log "REFUSED $name: not an integer ($val)"; return 1; }
  [ "$val" -ge "$lo" ] && [ "$val" -le "$hi" ] \
    || { log "REFUSED $name: $val outside ${lo}..${hi}"; return 1; }
  [ -w "$FAN/$file" ] || { log "REFUSED $name: $FAN/$file not writable"; return 1; }
  echo "$val" > "$FAN/$file" 2>/dev/null && echo c > "$FAN/$file" 2>/dev/null \
    && log "$name = $val" || { log "FAILED $name=$val"; return 1; }
}

write_status() {
  {
    echo "time=$(date +%s)"
    echo "cap_w=$(( $(cat "$H/power1_cap") / 1000000 ))"
    echo "cap_default_w=$(( $(cat "$H/power1_cap_default") / 1000000 ))"
    echo "perf_level=$(cat "$D/power_dpm_force_performance_level" 2>/dev/null)"
    echo "od_present=$([ -e "$OD" ] && echo yes || echo no)"
    echo "voff_range=$(od_range_voff 2>/dev/null || echo 'n/a')"
    echo "voff_now=$(awk '/^OD_VDDGFX_OFFSET:/{getline; gsub(/[^0-9-]/,""); print; exit}' "$OD" 2>/dev/null)"
    echo "vddgfx_mv=$(cat "$H/in0_input" 2>/dev/null)"
    if [ -d "$FAN" ]; then
      echo "fan_zero_rpm=$(fan_value fan_zero_rpm_enable)"
      echo "fan_target_temp=$(fan_value fan_target_temperature)"
      echo "fan_acoustic_target=$(fan_value acoustic_target_rpm_threshold)"
      echo "fan_acoustic_limit=$(fan_value acoustic_limit_rpm_threshold)"
      echo "fan_min_pwm=$(fan_value fan_minimum_pwm)"
    fi
    echo "last=$1"
  } > "$STATUS"
  chmod 0644 "$STATUS"
}

handle() {
  local verb="$1" arg="${2:-}"
  case "$verb" in
    ping)   return 0 ;;
    status) write_status "status"; return 0 ;;
    reset)  reset_all; write_status "reset"; return 0 ;;
    stop)   log "stop requested"; exit 0 ;;

    cap)
      is_int "$arg" || { log "REFUSED cap: not an integer ($arg)"; return 1; }
      [ "$arg" -ge "$CAP_MIN_W" ] && [ "$arg" -le "$CAP_MAX_W" ] \
        || { log "REFUSED cap: $arg outside ${CAP_MIN_W}..${CAP_MAX_W} W"; return 1; }
      local lo hi
      lo=$(( $(cat "$H/power1_cap_min") / 1000000 ))
      hi=$(( $(cat "$H/power1_cap_max") / 1000000 ))
      [ "$arg" -ge "$lo" ] && [ "$arg" -le "$hi" ] \
        || { log "REFUSED cap: $arg outside driver range ${lo}..${hi} W"; return 1; }
      echo $(( arg * 1000000 )) > "$H/power1_cap" \
        && log "cap = ${arg}W" || log "FAILED cap=${arg}"
      write_status "cap=$arg" ;;

    voffset)
      is_int "$arg" || { log "REFUSED voffset: not an integer ($arg)"; return 1; }
      [ "$arg" -ge "$VOFF_MIN_MV" ] && [ "$arg" -le "$VOFF_MAX_MV" ] \
        || { log "REFUSED voffset: $arg outside ${VOFF_MIN_MV}..${VOFF_MAX_MV} mV"; return 1; }
      [ -w "$OD" ] || { log "REFUSED voffset: OverDrive not exposed (kernel arg missing?)"; return 1; }
      local lo hi
      read -r lo hi < <(od_range_voff) || { log "REFUSED voffset: cannot read OD_RANGE"; return 1; }
      if is_int "$lo" && is_int "$hi"; then
        [ "$arg" -ge "$lo" ] && [ "$arg" -le "$hi" ] \
          || { log "REFUSED voffset: $arg outside driver range ${lo}..${hi} mV"; return 1; }
      fi
      echo "vo $arg" > "$OD" 2>/dev/null && echo c > "$OD" 2>/dev/null \
        && log "voffset = ${arg}mV" || log "FAILED voffset=${arg}"
      write_status "voffset=$arg" ;;

    # Fan knobs. Ranges match OD_RANGE as RDNA4 reports it; fan_set refuses
    # anything outside, and the driver refuses anything the ranges missed.
    fan-zero-rpm)        fan_set fan_zero_rpm_enable           "$arg" 0   1    "fan-zero-rpm"        && write_status "fan-zero-rpm=$arg" ;;
    fan-target-temp)     fan_set fan_target_temperature        "$arg" 25  105  "fan-target-temp"     && write_status "fan-target-temp=$arg" ;;
    fan-acoustic-target) fan_set acoustic_target_rpm_threshold "$arg" 500 6000 "fan-acoustic-target" && write_status "fan-acoustic-target=$arg" ;;
    fan-acoustic-limit)  fan_set acoustic_limit_rpm_threshold  "$arg" 500 6000 "fan-acoustic-limit"  && write_status "fan-acoustic-limit=$arg" ;;
    fan-min-pwm)         fan_set fan_minimum_pwm               "$arg" 30  100  "fan-min-pwm"         && write_status "fan-min-pwm=$arg" ;;

    fan-reset)
      if [ -d "$FAN" ]; then
        for f in "$FAN"/*; do [ -w "$f" ] && echo r > "$f" 2>/dev/null; done
        log "fan settings reset to defaults"
      fi
      write_status "fan-reset" ;;

    *) log "REFUSED unknown verb: $verb"; return 1 ;;
  esac
}

rm -f "$FIFO"
mkfifo -m 0620 "$FIFO"
chown "root:$(id -gn "$OWNER" 2>/dev/null || echo "$OWNER")" "$FIFO" 2>/dev/null \
  || chown "root:$OWNER" "$FIFO" 2>/dev/null
: > "$LOG"; chmod 0644 "$LOG"

# Held open read-write so the loop never sees EOF when a writer disconnects,
# which is what makes the read timeout -- and thus the watchdog -- reliable.
exec 3<> "$FIFO"

log "helper up (pid $$), fifo=$FIFO, watchdog=${WATCHDOG_S}s"
write_status "started"

while :; do
  if read -r -t "$WATCHDOG_S" -u 3 line; then
    [ -z "$line" ] && continue
    # shellcheck disable=SC2086
    set -- $line
    handle "$@"
  else
    log "WATCHDOG: no command for ${WATCHDOG_S}s -- reverting and exiting"
    exit 0
  fi
done
