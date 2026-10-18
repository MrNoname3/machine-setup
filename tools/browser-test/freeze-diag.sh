#!/bin/sh
# freeze-diag.sh [DIR]: run as root while Brave's picture is frozen; records
# where the GPU process waits (kernel stacks, five seconds of syscalls, and the
# threads' backtraces if gdb is there) into a new directory under DIR, owned by
# the user who ran sudo.
out=${1:-/var/tmp}/freeze-$(date +%H%M%S)
mkdir -p "$out"
gpu=$(pgrep -f -- '--type=gpu-process' | head -n 1)
echo "gpu=${gpu:-none}" > "$out/info"
if [ -n "$gpu" ]; then
  for t in /proc/"$gpu"/task/*; do
    echo "== $(cat "$t/comm") $(basename "$t") $(cat "$t/wchan")"
    cat "$t/stack"
  done > "$out/kstacks" 2>&1
  ls -l /proc/"$gpu"/fd > "$out/fds" 2>&1
  if command -v strace >/dev/null; then
    timeout 5 strace -f -tt -p "$gpu" -e trace=poll,ppoll,recvmsg,sendmsg,ioctl,futex,writev,read,write \
      -o "$out/strace" 2>/dev/null
  fi
  if command -v gdb >/dev/null; then
    gdb -p "$gpu" -batch -ex 'set pagination off' -ex 'thread apply all bt 25' > "$out/gdb" 2>&1
  fi
fi
[ -z "${SUDO_UID:-}" ] || chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$out"
echo "$out"
