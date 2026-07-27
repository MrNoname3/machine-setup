#!/usr/bin/env bash
# Read-only: what does THIS card actually offer? Run it first, and again after
# the reboot that activates the kernel argument.
#
# The point is to read the driver's own numbers rather than trust what forum
# posts say about RDNA OverDrive. Design the sweep from this output: the accepted
# offset range and the write syntax are properties of the card and firmware.

set -uo pipefail
. "$(dirname "$0")/common.sh"

D=$(gt_device) || exit 1
H=$(gt_hwmon "$D") || exit 1

echo "=== 1. card ==="
printf "  pci        : %s\n" "$(sed -n 's/^PCI_SLOT_NAME=//p' "$D/uevent")"
printf "  vbios      : %s\n" "$(cat "$D/vbios_version" 2>/dev/null)"
printf "  vram       : %s MiB (%s)\n" \
  "$(( $(cat "$D/mem_info_vram_total") / 1048576 ))" "$(cat "$D/mem_info_vram_vendor" 2>/dev/null)"

echo
echo "=== 2. is the OverDrive bit active? ==="
printf "  cmdline    : %s\n" "$(grep -o 'amdgpu.ppfeaturemask=[0-9a-fx]*' /proc/cmdline || echo '<not on the cmdline>')"
printf "  module     : %s\n" "$(cat /sys/module/amdgpu/parameters/ppfeaturemask)"
printf "  stock is 0xfff7bfff; 0xfff7ffff adds PP_OVERDRIVE_MASK and nothing else\n"

echo
echo "=== 3. OverDrive interfaces ==="
for f in pp_od_clk_voltage gpu_od; do
  [ -e "$D/$f" ] && echo "  present: $f" || echo "  MISSING: $f"
done

echo
echo "=== 4. pp_od_clk_voltage -- the ranges AND the syntax ==="
if [ -r "$D/pp_od_clk_voltage" ]; then
  sed 's/^/  /' "$D/pp_od_clk_voltage"
else
  echo "  <unreadable -- OverDrive is not active>"
fi

echo
echo "=== 5. fan control ==="
if [ -d "$D/gpu_od/fan_ctrl" ]; then
  for f in "$D"/gpu_od/fan_ctrl/*; do
    printf "  %-32s = %s\n" "$(basename "$f")" "$(gt_fan_value "$f")"
  done
else
  echo "  <no gpu_od/fan_ctrl>"
fi

echo
echo "=== 6. current state (should be stock before a study) ==="
printf "  power cap  : %sW (stock %sW, range %s..%sW)\n" \
  "$(( $(cat "$H/power1_cap") / 1000000 ))" "$(( $(cat "$H/power1_cap_default") / 1000000 ))" \
  "$(( $(cat "$H/power1_cap_min") / 1000000 ))" "$(( $(cat "$H/power1_cap_max") / 1000000 ))"
printf "  offset     : %s\n" "$(gt_offset_now "$D")"
printf "  perf level : %s\n" "$(cat "$D/power_dpm_force_performance_level")"

echo
echo "=== 7. GPU faults already in this boot (the sweep's baseline) ==="
printf "  count      : %s\n" "$(gt_kernel_faults "$(uptime -s)" | wc -l)"
