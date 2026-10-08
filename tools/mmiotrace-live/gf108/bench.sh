#!/bin/sh
#
# bench.sh [--validate] <name>
#
# A short glmark2 run on the NVIDIA GPU through PRIME offload, into
# bench-<name>.txt; with --validate, every glmark2 scene compared against its
# reference image instead, into validate-<name>.txt. It renders in the X
# session on :0: the live system's, through lightdm's authority file when run
# as root there, otherwise the calling user's.
#
mode=bench
if [ "${1:-}" = --validate ]; then
  mode=validate
  shift
fi
name=${1:?usage: bench.sh [--validate] <name>}

export DISPLAY="${DISPLAY:-:0}" DRI_PRIME=1
if [ -z "${XAUTHORITY:-}" ]; then
  if [ -r /var/run/lightdm/root/:0 ]; then
    XAUTHORITY=/var/run/lightdm/root/:0
  else
    XAUTHORITY=$HOME/.Xauthority
  fi
  export XAUTHORITY
fi

if [ $mode = validate ]; then
  exec glmark2 --off-screen --validate >"validate-$name.txt" 2>&1
fi
exec glmark2 --off-screen -s 800x600 -b build:use-vbo=true -b texture:texture-filter=linear \
  -b shading:shading=phong -b bump:bump-render=normals \
  -b 'effect2d:kernel=0,1,0;1,-4,1;0,1,0;' >"bench-$name.txt" 2>&1
