#!/usr/bin/env bash
# series.sh USER PLAN RESULTS — as root: run.sh as USER once per plan line, results in
# RESULTS/<label>. A plan line is
#   <label> <dd|build> <scale> <scheduler|-> <settings|-> [podman options...]
# with the scheduler of the physical disk (- leaves it) and settings as k=v,k=v:
#   vm.<sysctl>=V    e.g. vm.dirty_bytes=268435456
#   iocost=1         the io.cost controller on the disk, default cost model
#   weight=N         IOWeight of USER's user.slice, where the jobs run
#   compress=TYPE    remount the measured btrfs with that compression
# Everything is restored after each run. USER's gitea-runner.service is stopped for the series
# and started again at the end, unless a CI job is running, which aborts the series.
# dstate.py records the desktop's blocked threads into RESULTS/dstate.jsonl.
set -u
user=$1 plan=$(realpath "$2") res=$(realpath -m "$3")
here=$(cd "$(dirname "$0")" && pwd -P)
home=$(getent passwd "$user" | cut -d: -f6); uid=$(id -u "$user")
cd "$home" || exit 1
as_user() {
  runuser -u "$user" -- env HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" PATH=/usr/local/bin:/usr/bin:/bin \
    IOTEST_IMAGE="${IOTEST_IMAGE:-}" IOTEST_JOBS="${IOTEST_JOBS:-}" "$@" </dev/null
}
as_user mkdir -p "$res"
# shellcheck source=devices.sh
. "$here/devices.sh"; iotest_devices "$res"
q=/sys/block/$IOTEST_DISK/queue/scheduler
# shellcheck disable=SC2016  # expands in the user's shell
log() { as_user sh -c 'echo "$(date +%T) $1" >> "$2"' _ "$*" "$res/series.log"; }

sched0=$(sed -E 's/.*\[(.*)\].*/\1/' "$q")
declare -A vm0
for k in dirty_ratio dirty_background_ratio dirty_bytes dirty_background_bytes; do vm0[$k]=$(sysctl -n "vm.$k"); done
compress0=$(findmnt -no OPTIONS "$IOTEST_MNT" | tr , '\n' | grep -E '^compress(-force)?=' || echo compress=no)
set_iocost=false set_weight=false set_compress=false
restore() {
  echo "$sched0" > "$q"
  $set_iocost && echo "$IOTEST_DISK_DEV enable=0" > /sys/fs/cgroup/io.cost.qos
  $set_weight && as_user systemctl --user revert user.slice >/dev/null 2>&1
  $set_compress && mount -o remount,"$compress0" "$IOTEST_SRC" "$IOTEST_MNT"
  for k in "${!vm0[@]}"; do
    case $k in
      # writing one of a ratio/bytes pair zeroes the other, and 0 bytes is rejected
      dirty_ratio|dirty_background_ratio) [ "${vm0[${k%ratio}bytes]}" != 0 ] || sysctl -qw "vm.$k=${vm0[$k]}" ;;
      dirty_bytes|dirty_background_bytes) [ "${vm0[$k]}" = 0 ] || sysctl -qw "vm.$k=${vm0[$k]}" ;;
      *) sysctl -qw "vm.$k=${vm0[$k]}" ;;
    esac
  done
  set_iocost=false set_weight=false set_compress=false
}

finish() {
  kill -INT "$dstate" 2>/dev/null; wait "$dstate" 2>/dev/null
  restore
  log "restored scheduler=$(sed -E 's/.*\[(.*)\].*/\1/' "$q") vm=$(sysctl -n vm.dirty_ratio vm.dirty_background_ratio vm.dirty_bytes | paste -sd' ')"
  $runner && as_user systemctl --user start gitea-runner.service && log "gitea-runner.service started"
  log "series finished"
}
runner=false dstate=""
trap finish EXIT
if as_user systemctl --user is-active -q gitea-runner.service; then
  if as_user podman ps -a --format '{{.Names}}' | grep -q GITEA-ACTIONS \
     || as_user podman volume ls --format '{{.Name}}' | grep -q GITEA-ACTIONS-TASK; then
    log "ABORT: a CI job is running"; exit 3
  fi
  as_user systemctl --user stop gitea-runner.service && runner=true && log "gitea-runner.service stopped"
fi
as_user touch "$res/dstate.jsonl"
python3 -I "$here/dstate.py" "$res/dstate.jsonl" & dstate=$!
log "fs=$IOTEST_FS ($IOTEST_FS_DEV) on $IOTEST_MNT, disk=$IOTEST_DISK ($IOTEST_DISK_DEV), dm-crypt: ${IOTEST_CRYPT:-none}"

total=$(grep -cv '^\s*\(#\|$\)' "$plan"); n=0
while read -r label load scale sched sets opts; do
  case $label in ''|'#'*) continue ;; esac
  n=$((n + 1))
  [ "$sched" = - ] || echo "$sched" > "$q"
  if [ "$sets" != - ]; then
    IFS=, read -ra kv <<<"$sets"
    for a in "${kv[@]}"; do
      case $a in
        iocost=1) echo "$IOTEST_DISK_DEV enable=1" > /sys/fs/cgroup/io.cost.qos; set_iocost=true ;;
        weight=*) as_user systemctl --user set-property --runtime user.slice "IOWeight=${a#weight=}"; set_weight=true ;;
        compress=*) mount -o remount,"$a" "$IOTEST_SRC" "$IOTEST_MNT"; set_compress=true ;;
        vm.*=*)
          k=${a%%=*}; k=${k#vm.}
          [ -n "${vm0[$k]+set}" ] || vm0[$k]=$(sysctl -n "vm.$k")
          sysctl -qw "$a" ;;
        *) log "unknown setting $a"; exit 2 ;;
      esac
    done
  fi
  crypt=""
  for c in $IOTEST_CRYPT; do crypt+="$c:[$(dmsetup table "$c" | cut -d' ' -f9-)] "; done
  log "[$n/$total] $label: $load $scale sched=$(sed -E 's/.*\[(.*)\].*/\1/' "$q") settings=$sets opts=$opts" \
      "dm-crypt=${crypt:-none} discard_max=$(cat "/sys/block/$IOTEST_FS/queue/discard_max_bytes")" \
      "mount=[$(findmnt -no OPTIONS "$IOTEST_MNT")]"
  # shellcheck disable=SC2086
  as_user timeout -k 30 1800 "$here/run.sh" "$res/$label" "$load" "$scale" $opts >/dev/null 2>&1
  log "[$n/$total] $label exit=$?"
  restore
  sleep 30
done < "$plan"
