#!/bin/sh
#
# clocks.sh
#
# Measures clocks with the GPU's own counters, which nouveau's pstate table does
# not do: each counts its clock for 0x3fff periods of the 27 MHz crystal. On
# the GF108 they measure the shader clock (twice the core clock), domain 7
# (hub06) and the SPPLL reference. Needs nvreg and a GPU that is powered up.
#
as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

count() { # count <control register>: the counter's MHz
  as_root nvreg w "$1" 0x01010000
  as_root nvreg w "$1" 0x00113fff
  sleep 0.002
  v=$(as_root nvreg r $(($1 + 4)) | cut -d' ' -f2)
  as_root nvreg w "$1" 0x01010000
  [ "$v" = ffffffff ] && { echo "clocks.sh: the GPU does not answer (powered off?)" >&2; exit 1; }
  echo "$((0x$v)) * 27 / 16383" | bc -l
}

printf 'shader %7.1f MHz\n' "$(count 0x1373c0)"
printf 'hub06  %7.1f MHz\n' "$(count 0x1373b0)"
printf 'SPPLL  %7.1f MHz\n' "$(count 0x1373b8)"
