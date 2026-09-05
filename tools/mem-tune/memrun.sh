#!/bin/sh
#
# memrun.sh <label> [--cap]
#
# One labelled measurement of a machine's memory: what the modules are, how
# fast memory answers, how much of it can be pushed through, and how large a
# working set the machine can actually hold.
#
# Run the same command before and after a change and compare the two files.
# The comparison is only meaningful when both sides were measured under the
# same conditions, which is why every run starts by recording them: kernel,
# power profile, governor, boost state, clock ceiling and the memory-related
# kernel knobs. A power profile that disables boost or pins the clock will move
# these numbers further than most hardware changes do, and it does so silently.
#
# Results are written outside the repository -- they describe one machine at
# one moment, and a sweep produces a lot of them.
#
# Environment:
#   MT_STATE      where results and built binaries live
#                 (default ~/.local/state/mem-tune)
#   MT_CPU        core to pin the latency test to. Use the same one on every
#                 run being compared; the default avoids core 0, which tends to
#                 carry interrupt work.
#   MT_BW_MIB     working set per bandwidth array. The default is derived from
#                 the last-level cache, because a bandwidth test whose arrays
#                 fit in cache reports a figure the memory could never deliver.
#   MT_CAP_SIZES  working-set ladder for --cap, in MiB. Deliberately absolute
#                 rather than a fraction of installed memory, so that a run
#                 before a capacity change and one after it use the same steps.
#
set -e

SRC=$(dirname "$(readlink -f "$0")")
LABEL=${1:?usage: memrun.sh <label> [--cap]}
WANT_CAP=${2:-}

MT_STATE=${MT_STATE:-$HOME/.local/state/mem-tune}
BIN="$MT_STATE/bin"
OUT="$MT_STATE/results/$LABEL.txt"
mkdir -p "$BIN" "$MT_STATE/results"

NPROC=$(nproc 2>/dev/null || echo 1)
MT_CPU=${MT_CPU:-$((NPROC / 4))}
# Size the bandwidth arrays well past last-level cache. Without this the test
# silently measures cache instead of memory and reports several times the real
# figure -- an easy mistake to publish, and a hard one to notice.
llc_mib() {
	best=0
	for f in /sys/devices/system/cpu/cpu0/cache/index*/size; do
		[ -r "$f" ] || continue
		v=$(cat "$f")
		case "$v" in
		*M) v=${v%M} ;;
		*K) v=$(( ${v%K} / 1024 )) ;;
		*) continue ;;
		esac
		[ "$v" -gt "$best" ] && best=$v
	done
	echo "$best"
}
LLC=$(llc_mib)
MT_BW_MIB=${MT_BW_MIB:-$(( LLC * 8 > 192 ? LLC * 8 : 192 ))}
MT_CAP_SIZES=${MT_CAP_SIZES:-"2000 4000 6000 8000 10000 12000 14000 18000 22000 26000 32000 40000 48000"}

# Rebuild only what changed, so a run is a single command from a clean checkout.
build() {
	out=$1 src=$2
	shift 2
	if [ ! -x "$out" ] || [ "$src" -nt "$out" ]; then
		cc -O2 -o "$out" "$src" "$@" || return 1
	fi
}
build "$BIN/lat" "$SRC/lat.c"
build "$BIN/cap" "$SRC/cap.c"
build "$BIN/bw" "$SRC/bw.c" -fopenmp || echo "warning: bw needs OpenMP; skipping bandwidth" >&2

# Reading module information needs root. Without it those sections are skipped
# and everything else still runs.
if [ "$(id -u)" -eq 0 ]; then
	SUDO=""
elif ! command -v sudo >/dev/null 2>&1; then
	SUDO="skip"
elif [ -n "${SUDO_ASKPASS:-}" ]; then
	SUDO="sudo -A"
else
	SUDO="sudo"
fi

power_profile() {
	if command -v tuned-adm >/dev/null 2>&1; then
		tuned-adm active 2>/dev/null | sed 's/.*: //' && return
	fi
	if command -v powerprofilesctl >/dev/null 2>&1; then
		powerprofilesctl get 2>/dev/null && return
	fi
	echo "(none reported)"
}

cpufreq() {
	f=/sys/devices/system/cpu/cpu0/cpufreq/$1
	[ -r "$f" ] && cat "$f" || echo "-"
}

{
echo "=== label: $LABEL   $(date -Is) ==="
echo
echo "--- conditions (a comparison is only valid against a run that matches) ---"
echo "kernel         : $(uname -r)"
echo "power profile  : $(power_profile)"
echo "governor       : $(cpufreq scaling_governor)"
echo "energy pref    : $(cpufreq energy_performance_preference)"
echo "boost          : $(cpufreq boost)"
echo "clock ceiling  : $(cpufreq scaling_max_freq) kHz"
echo "latency pinned : cpu$MT_CPU of $NPROC"
echo "MemTotal       : $(awk '/^MemTotal/{print $2}' /proc/meminfo) kB"
echo "MemAvailable   : $(awk '/^MemAvailable/{print $2}' /proc/meminfo) kB"
echo "swappiness     : $(cat /proc/sys/vm/swappiness 2>/dev/null || echo -)"
echo "page-cluster   : $(cat /proc/sys/vm/page-cluster 2>/dev/null || echo -)"
if command -v zramctl >/dev/null 2>&1; then
	echo "compressed swap: $(zramctl --noheadings -o NAME,ALGORITHM,DISKSIZE 2>/dev/null | tr -s ' ' | tr '\n' ';')"
fi

echo
echo "--- modules as trained ---"
if [ "$SUDO" = "skip" ]; then
	echo "  (needs root)"
else
	$SUDO dmidecode -t 17 2>/dev/null | awk '
		/^Memory Device/           { loc=""; size=""; speed=""; part=""; rank="" }
		/Locator:/ && !/Bank/      { loc=$2 }
		/^\tSize:/                 { size=$2" "$3 }
		/Configured Memory Speed:/ { speed=$4" "$5 }
		/Part Number:/             { part=$3 }
		/^\tRank:/                 { rank=$2 }
		/^\tConfigured Voltage:/   { printf "  %-9s %-9s %-11s rank=%-3s %-18s %s\n", loc, size, speed, rank, part, $3"V" }
	' || echo "  (dmidecode unavailable)"

	echo
	echo "--- what each module asks for ---"
	$SUDO python3 "$SRC/spd.py" 2>&1 || true
fi

echo
echo "--- latency, min of repeated passes, two independent runs ---"
taskset -c "$MT_CPU" "$BIN/lat"
taskset -c "$MT_CPU" "$BIN/lat"

if [ -x "$BIN/bw" ]; then
	echo
	echo "--- bandwidth, ${MT_BW_MIB} MiB arrays, best of five passes ---"
	t=1
	while [ "$t" -le "$NPROC" ]; do
		"$BIN/bw" "$t" "$MT_BW_MIB"
		t=$((t * 2))
	done
fi

if [ "$WANT_CAP" = "--cap" ]; then
	echo
	echo "--- capacity: working set against eviction and stall ---"
	for mb in $MT_CAP_SIZES; do
		if ! result=$("$BIN/cap" "$mb" 5 2>&1); then
			printf '%6s MiB | not attempted: %s\n' "$mb" "$result"
			break
		fi
		echo "$result"
		# Stop climbing once the machine is genuinely thrashing: past this
		# point the run tells us nothing new and risks an OOM kill.
		swapped_in=$(echo "$result" | sed -n 's/.*swap-in *\([0-9]*\).*/\1/p')
		if [ "${swapped_in:-0}" -gt 400000 ]; then
			echo "  (stopped: eviction passed the safety threshold)"
			break
		fi
		sleep 5
	done
fi
echo
echo "=== end ==="
} 2>&1 | tee "$OUT"

echo
echo "saved: $OUT"
