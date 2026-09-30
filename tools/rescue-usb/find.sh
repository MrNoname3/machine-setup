#!/usr/bin/env bash
#
# find.sh [a.b.c]
#
# Prints the address of the machine booted from the rescue stick: the host in
# a.b.c.1-254 that presents the SSH host key build.sh baked in. The network
# defaults to the /24 of the default gateway.
#
#   ssh -o HostName="$(./find.sh)" rescue
#
set -euo pipefail

RU_STATE=${RU_STATE:-$HOME/.local/state/rescue-usb}
want=$(cut -d' ' -f2,3 "$RU_STATE/known_hosts")

net=${1:-}
if [ -z "$net" ]; then
  # /proc/net/route stores the gateway as little-endian hex.
  gw=$(awk '$2 == "00000000" && $3 != "00000000" { print $3; exit }' /proc/net/route)
  [ -n "$gw" ] || { echo "find.sh: no default gateway; pass the network as a.b.c" >&2; exit 2; }
  net=$(printf '%d.%d.%d' "0x${gw:6:2}" "0x${gw:4:2}" "0x${gw:2:2}")
fi

seq 1 254 | sed "s/^/$net./" |
  ssh-keyscan -T 3 -t ed25519 -f - 2>/dev/null |
  awk -v want="$want" '$2 " " $3 == want { print $1; found = 1 } END { exit !found }' ||
  { echo "find.sh: no host on $net.0/24 presents the rescue host key" >&2; exit 1; }
