#!/usr/bin/env bash
#
# falcon-dump.sh [-d <pci-device>] <falcon-base> <prefix>
#
# Reads a falcon microcontroller's memories through its IO windows while it
# runs: code memory (CODE_INDEX/CODE at +0x180/+0x184, read auto-increment),
# the virtual page each physical code page holds (PTLB through TLB_CMD at
# +0x140, result at +0x144), and data memory through data window 1
# (+0x1c8/+0x1cc), which drivers leave alone. Sizes come from UC_CAPS (+0x108).
# Writes <prefix>-caps.txt, -imem.txt, -tlb.txt and -dmem.txt, one hex word a
# line; falcon-image.py turns them into images. The PMU sits at 0x10a000.
#
# Runs as root, with nvreg (nvreg.c) on PATH. What it reads is the GPU maker's
# firmware: keep it, do not publish it.
#
set -euo pipefail

dev=()
if [ "${1:-}" = -d ]; then dev=(-d "$2"); shift 2; fi
base=$(( ${1:?usage: falcon-dump.sh [-d <pci-device>] <falcon-base> <prefix>} ))
prefix=${2:?usage: falcon-dump.sh [-d <pci-device>] <falcon-base> <prefix>}

reg() { printf '0x%06x' $((base + $1)); }
words() { # words <count> <line>: the line, count times
  local i
  for ((i = 0; i < $1; i++)); do echo "$2"; done
}

caps=$(nvreg "${dev[@]}" r "$(reg 0x108)" | awk '{print $2}')
code=$(( (0x$caps & 0x1ff) << 8 ))
data=$(( (0x$caps & 0x3fe00) >> 1 ))
echo "caps $caps code $code data $data" >"$prefix-caps.txt"

{ echo "w $(reg 0x180) 0x02000000"; words $((code / 4)) "r $(reg 0x184)"; } |
  nvreg "${dev[@]}" - | awk '{print $2}' >"$prefix-imem.txt"
for ((i = 0; i < code / 256; i++)); do
  printf 'w %s 0x%08x\nr %s\n' "$(reg 0x140)" $((2 << 24 | i)) "$(reg 0x144)"
done | nvreg "${dev[@]}" - | awk '{print $2}' >"$prefix-tlb.txt"
{ echo "w $(reg 0x1c8) 0x02000000"; words $((data / 4)) "r $(reg 0x1cc)"; } |
  nvreg "${dev[@]}" - | awk '{print $2}' >"$prefix-dmem.txt"

echo "$prefix: $code bytes of code, $data of data," \
  "$(grep -vc '^00000000$' "$prefix-imem.txt") nonzero code words"
