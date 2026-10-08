#!/usr/bin/env bash
#
# trace-clocks.sh <output-file>
#
# Records with mmiotrace how the NVIDIA driver starts and then moves between
# its performance levels: it loads the driver, starts an X server on the GPU
# (xorg-nvidia.conf), waits for the lowest level, runs glmark2 until the
# highest and a while longer, and waits for the lowest level again. Every step
# and every level change goes into the trace as a MARK line.
#
# Runs as root on the mmiotrace live system, before anything loaded the driver.
#
# Environment:
#   MT_BUFFER_KB  trace buffer per CPU, in KiB (default 262144)
#   MT_LOAD_SECS  how long glmark2 keeps running at the highest level (default 20)
#
set -euo pipefail

SRC=$(dirname "$(readlink -f "$0")")
OUT=${1:?usage: trace-clocks.sh <output-file>}
MT_BUFFER_KB=${MT_BUFFER_KB:-262144}
MT_LOAD_SECS=${MT_LOAD_SECS:-20}
T=/sys/kernel/tracing
DPY=:1

die() { printf 'trace-clocks.sh: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ -e $T/trace_marker ] || mount -t tracefs nodev $T
grep -qw mmiotrace $T/available_tracers || die "this kernel has no mmiotrace"
! lsmod | grep -q '^nvidia ' || die "nvidia is loaded; the trace has to start before it"
! pgrep -a -x Xorg | grep -q " $DPY " || die "an X server already runs on $DPY"

mark() { echo "$*" >$T/trace_marker; printf '%s %s\n' "$(date +%T)" "$*"; }
query() { DISPLAY=$DPY nvidia-settings -t -q "[gpu:0]/$1" 2>/dev/null | head -1; }

last=
wait_level() { # wait_level <level> <timeout-seconds>, marking each change
  local want=$1 end=$((SECONDS + $2)) cur
  while :; do
    cur=$(query GPUCurrentPerfLevel)
    if [ "$cur" != "$last" ]; then
      mark "level $cur clocks $(query GPUCurrentClockFreqs)"
      last=$cur
    fi
    [ "$cur" != "$want" ] || return 0
    [ $SECONDS -lt "$end" ] || die "level $want not reached in $2 s"
    sleep 2
  done
}

xpid='' catpid='' gpid=''
cleanup() {
  [ -z "$gpid" ] || kill "$gpid" 2>/dev/null || true
  [ -z "$xpid" ] || { kill "$xpid" 2>/dev/null; wait "$xpid" 2>/dev/null; } || true
  # The tracer cannot change while trace_pipe is open: stop recording, let the
  # reader drain the buffer, stop it, then turn the tracer off, which also
  # brings the other CPUs back online.
  echo 0 >$T/tracing_on
  [ -z "$catpid" ] || { sleep 3; kill "$catpid" 2>/dev/null; wait "$catpid" 2>/dev/null; } || true
  echo nop >$T/current_tracer
  echo 1 >$T/tracing_on
}
trap cleanup EXIT

echo nop >$T/current_tracer
echo "$MT_BUFFER_KB" >$T/buffer_size_kb
echo mmiotrace >$T/current_tracer
cat $T/trace_pipe >"$OUT" &
catpid=$!

mark "load driver"
modprobe --ignore-install nvidia

mark "start X"
Xorg $DPY -config "$SRC/xorg-nvidia.conf" -logfile "$OUT.Xorg.log" \
  -noreset -nolisten tcp -sharevts -novtswitch vt7 </dev/null >/dev/null 2>&1 &
xpid=$!
for _ in $(seq 120); do DISPLAY=$DPY xdpyinfo >/dev/null 2>&1 && break; sleep 1; done
DISPLAY=$DPY xdpyinfo >/dev/null 2>&1 || die "X did not start on $DPY"
mark "X up"

wait_level 0 300

mark "load start"
DISPLAY=$DPY glmark2 -s 800x600 --run-forever >/dev/null 2>&1 &
gpid=$!
wait_level 2 120
sleep "$MT_LOAD_SECS"
kill "$gpid"; wait "$gpid" 2>/dev/null || true; gpid=
mark "load stop"

wait_level 0 300

mark "stop X"
kill "$xpid"; wait "$xpid" 2>/dev/null || true; xpid=

mark "unload driver"
for m in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
  ! lsmod | grep -q "^$m " || rmmod "$m"
done
mark "end"
