#!/usr/bin/env bash
# Shared helpers. Sourced by every script here; not meant to be run directly.
#
# Everything machine-specific is resolved at runtime rather than written into the
# scripts, so this set works on any amdgpu card and survives the card index and
# hwmon index moving between boots.

# --- device discovery ------------------------------------------------------
# GPU_PCI can be set in the environment to pick a specific card on a multi-GPU
# machine; otherwise the first amdgpu device wins.
gt_device() {
  local d
  if [ -n "${GPU_PCI:-}" ]; then
    d="/sys/bus/pci/devices/$GPU_PCI"
    [ -d "$d" ] || { echo "no such device: $GPU_PCI" >&2; return 1; }
    printf '%s' "$d"; return 0
  fi
  for d in /sys/class/drm/card*/device; do
    [ -r "$d/uevent" ] || continue
    grep -qx 'DRIVER=amdgpu' "$d/uevent" 2>/dev/null && { printf '%s' "$d"; return 0; }
  done
  echo "no amdgpu device found (set GPU_PCI to override)" >&2
  return 1
}

gt_hwmon() {
  local dev="$1" h
  for h in "$dev"/hwmon/hwmon*; do
    [ -r "$h/name" ] && [ "$(cat "$h/name")" = amdgpu ] && { printf '%s' "$h"; return 0; }
  done
  echo "no amdgpu hwmon under $dev" >&2
  return 1
}

# --- paths -----------------------------------------------------------------
# Results live outside the repo: they are machine- and session-specific data,
# not configuration, and a sweep produces hundreds of files.
GT_STATE="${GT_STATE:-$HOME/.local/state/gpu-tune}"
GT_LOGS="$GT_STATE/logs"
GT_RESULTS="$GT_STATE/results"
mkdir -p "$GT_LOGS" "$GT_RESULTS" 2>/dev/null || true

# --- the privileged helper's interface ------------------------------------
GT_FIFO=/run/amdgpu-tune-session.fifo
GT_STATUS=/run/amdgpu-tune-session.status
GT_HELPER_LOG=/run/amdgpu-tune-session.log

gt_require_helper() {
  [ -p "$GT_FIFO" ] && return 0
  cat >&2 <<EOF
The privileged helper is not running. Start it (one password prompt):

  SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/amdgpu-tuned.sh &

EOF
  return 1
}

gt_cmd() { printf '%s\n' "$*" > "$GT_FIFO"; sleep "${GT_CMD_SETTLE:-2}"; }

# Feed the helper's watchdog during long benchmarks, which send no commands of
# their own. Call gt_pinger_start before a long run and gt_pinger_stop after.
gt_pinger_start() {
  ( while :; do sleep 240; printf 'ping\n' > "$GT_FIFO" 2>/dev/null || exit 0; done ) &
  GT_PINGER=$!
}
gt_pinger_stop() { [ -n "${GT_PINGER:-}" ] && kill "$GT_PINGER" 2>/dev/null; GT_PINGER=; }

# --- reading the GPU -------------------------------------------------------
# The APPLIED offset, not the range line -- /VDDGFX_OFFSET/ alone matches
# OD_RANGE first and would return the range's bounds as if they were a setting.
gt_offset_now() {
  awk '/^OD_VDDGFX_OFFSET:/{getline; gsub(/[^0-9-]/,""); print; exit}' \
    "$1/pp_od_clk_voltage" 2>/dev/null
}

gt_offset_range() {
  awk '/VDDGFX_OFFSET/ && NF>=3 {gsub(/[mM][vV]/,"",$2); gsub(/[mM][vV]/,"",$3); print $2, $3; exit}' \
    "$1/pp_od_clk_voltage" 2>/dev/null
}

# gpu_od/fan_ctrl files put the label on line 1 and the value on line 2.
gt_fan_value() { awk 'NR==2{print $1}' "$1" 2>/dev/null; }

# --- the reference run -----------------------------------------------------
# Comparisons read the untuned baseline from its result file rather than from a
# constant, so a rerun on different hardware compares against ITS OWN reference.
GT_BASELINE_LABEL="${GT_BASELINE_LABEL:-baseline-stock}"

gt_baseline_fps() {
  local f="$GT_RESULTS/${GT_BASELINE_LABEL}.tsv"
  [ -r "$f" ] || { echo "no baseline at $f -- run: ./bench.sh $GT_BASELINE_LABEL 4" >&2; return 1; }
  awk -F'\t' 'NR>1 && $11=="no" {s+=$4; n++} END {if(n) printf "%.1f", s/n; else exit 1}' "$f"
}

# --- instability detection -------------------------------------------------
# Three independent signals, because an undervolt fails in three ways and only
# one of them is loud. Any hit means the setting is not safe.
gt_kernel_faults() {
  journalctl -k --since "$1" --no-pager 2>/dev/null \
    | grep -iE 'gpu reset|ring.*timeout|GPU fault|amdgpu.*hang|VM_L2|page fault'
}

gt_artifacts() {
  grep -aiE 'artifact' "$@" 2>/dev/null \
    | grep -aivE 'artifact-scanner-interval|scanner *: *(off|disabled)'
}

# --- the benchmark ---------------------------------------------------------
# The flatpak's default command is the GUI launcher, which silently ignores
# every CLI flag -- it has to be told to run the furmark binary instead.
GT_FURMARK=(flatpak run --user --command=furmark com.geeks3d.furmark)
GT_DEMO="${GT_DEMO:-furmark-vk}"

gt_require_furmark() {
  flatpak info --user com.geeks3d.furmark >/dev/null 2>&1 && return 0
  echo "FurMark is not installed. See README.md (Setup)." >&2
  return 1
}
