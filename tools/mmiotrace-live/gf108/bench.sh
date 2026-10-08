#!/bin/sh
# bench.sh <name>: a short glmark2 run on the NVIDIA GPU through PRIME offload.
export DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 DRI_PRIME=1
glmark2 --off-screen -s 800x600 -b build:use-vbo=true -b texture:texture-filter=linear \
  -b shading:shading=phong -b bump:bump-render=normals \
  -b 'effect2d:kernel=0,1,0;1,-4,1;0,1,0;' >"bench-$1.txt" 2>&1
