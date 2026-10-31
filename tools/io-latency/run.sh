#!/usr/bin/env bash
# run.sh OUTDIR dd|build SCALE [podman options...] — one measurement, as the desktop user.
# IOTEST_JOBS containers (3) from IOTEST_IMAGE write in parallel while probe.py and readlat.py
# measure the desktop side from app.slice. dd: SCALE GiB of zeros per job; build: SCALE tar
# copies of the image's /usr per job, deleted with the container. OUTDIR must be on the
# filesystem to measure; its parent keeps readtarget.dat, the read probe's 1 GiB of data.
set -u
out=$(realpath -m "$1") load=$2 scale=$3; shift 3
here=$(cd "$(dirname "$0")" && pwd -P)
image=${IOTEST_IMAGE:-ghcr.io/catthehacker/ubuntu:act-latest}
jobs=${IOTEST_JOBS:-3} limit=1200
mkdir -p "$out/jobs"
# shellcheck source=devices.sh
. "$here/devices.sh"; iotest_devices "$out"
log() { echo "$(date +%T) $*" >> "$out/run.log"; }
mapfile -t names < <(seq -f 'iotest-%g' "$jobs")
cleanup() {
  kill -INT "$probe" "$reader" 2>/dev/null; wait "$probe" "$reader" 2>/dev/null
  podman rm -f -t 0 "${names[@]}" >/dev/null 2>&1
}
trap cleanup EXIT

# Refuse to measure on top of a CI job: its container, or its volumes while it reports.
if podman ps -a --format '{{.Names}}' | grep -q GITEA-ACTIONS \
   || podman volume ls --format '{{.Name}}' | grep -q GITEA-ACTIONS-TASK; then
  log "ABORT: a CI job is present"; echo '{"aborted": "ci job present"}' > "$out/meta.json"; exit 3
fi

# shellcheck disable=SC2016  # the build loop expands in the container
case $load in
  dd)    cmd="dd if=/dev/zero of=/w/big bs=1M count=$((scale * 1024)) status=none" ;;
  # GNU cp reflinks on btrfs and would write almost nothing; a tar pipe writes every byte.
  build) cmd='for i in $(seq '"$scale"'); do mkdir /w/u$i; tar -C / -cf - usr | tar -C /w/u$i -xf -; done' ;;
  *) echo "unknown load $load" >&2; exit 2 ;;
esac

target=$(dirname "$out")/readtarget.dat
[ -s "$target" ] || { head -c 1G /dev/urandom > "$target" && sync "$target"; }

since=$(date '+%Y-%m-%d %H:%M:%S')
scope() { exec systemd-run --user --scope --slice=app.slice --quiet "$@"; }
scope python3 -I "$here/probe.py" "$out/probe.json" "$IOTEST_FS" "$IOTEST_DISK" & probe=$!
scope python3 -I "$here/readlat.py" "$target" "$out/readlat.json" & reader=$!
sleep 15

fs_before=$(awk '{print $7}' "/sys/block/$IOTEST_FS/stat")
# CPU time of the whole machine in USER_HZ ticks, the kernel's writeback and compression included
busy() { awk '$1 == "cpu" {print $2 + $3 + $4 + $7 + $8 + $9}' /proc/stat; }
cpu_before=$(busy)
t_start=$(date +%s.%N)
for i in $(seq "$jobs"); do
  podman run -d --rm --pull=never --name "iotest-$i" -v "$out/jobs:/out:z" "$@" "$image" bash -c "
    mkdir -p /w; s=\$(date +%s.%N); $cmd; e=\$(date +%s.%N)
    echo \"{\\\"start\\\": \$s, \\\"end\\\": \$e}\" > /out/job$i.json; sleep $limit" >/dev/null \
    || { log "ABORT: podman run failed for iotest-$i"; echo '{"aborted": "podman run failed"}' > "$out/meta.json"; exit 4; }
done
cgs=()
for i in $(seq "$jobs"); do cgs+=("$(podman inspect -f '{{.State.CgroupPath}}' "iotest-$i")"); done
log "started $load scale=$scale opts=$* fs=$IOTEST_FS disk=$IOTEST_DISK"

# Wait for the jobs through the bind mount: podman itself stalls under heavy I/O.
deadline=$(( $(date +%s) + limit ))
while [ "$(find "$out/jobs" -name 'job*.json' | wc -l)" -lt "$jobs" ]; do
  [ "$(date +%s)" -lt "$deadline" ] || { log "ABORT: jobs did not finish in ${limit}s"; break; }
  sleep 1
done
# Let writeback drain while the containers still exist, so io.stat holds everything they wrote.
drain_deadline=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$drain_deadline" ]; do
  pending=0
  for cg in "${cgs[@]}"; do
    p=$(awk '$1 == "file_dirty" || $1 == "file_writeback" {s += $2} END {print s + 0}' "/sys/fs/cgroup$cg/memory.stat" 2>/dev/null)
    pending=$(( pending + ${p:-0} ))
  done
  [ "$pending" -lt 1048576 ] && break
  sleep 2
done
log "drained (pending=$pending)"
# Without the io controller delegated to the user's session there is no io.stat: null.
jobs_wbytes=0
for cg in "${cgs[@]}"; do
  [ -e "/sys/fs/cgroup$cg/io.stat" ] || { jobs_wbytes=null; break; }
  b=$(awk -v dev="$IOTEST_FS_DEV" '$1 == dev {for (i = 2; i <= NF; i++) if ($i ~ /^wbytes=/) {sub("wbytes=", "", $i); print $i}}' "/sys/fs/cgroup$cg/io.stat")
  jobs_wbytes=$(( jobs_wbytes + ${b:-0} ))
done
fs_after=$(awk '{print $7}' "/sys/block/$IOTEST_FS/stat")
cpu_after=$(busy)
podman rm -f -t 0 "${names[@]}" >/dev/null 2>&1
sleep 20
t_end=$(date +%s.%N)
kill -INT "$probe" "$reader"; wait "$probe" "$reader" 2>/dev/null
# KWin's message when its main thread blocked long enough to miss a frame
kwin=$(journalctl --user --since "$since" --no-pager -o cat | grep -ci 'main thread was hanging')
sched=$(sed -E 's/.*\[(.*)\].*/\1/' "/sys/block/$IOTEST_DISK/queue/scheduler")
cat > "$out/meta.json" <<JSON
{"load": "$load", "scale": $scale, "jobs": $jobs, "opts": "$*", "scheduler": "$sched",
 "fs": "$IOTEST_FS", "disk": "$IOTEST_DISK", "t_start": $t_start, "t_end": $t_end, "kwin_hangs": $kwin,
 "fs_written": $(( (fs_after - fs_before) * 512 )), "jobs_written": $jobs_wbytes,
 "cpu_busy_s": $(( (cpu_after - cpu_before) / $(getconf CLK_TCK) ))}
JSON
log "done"
