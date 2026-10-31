#!/usr/bin/env bash
# Keep a remote Mint machine awake while working on it over SSH.
#
#   ./scripts/awake-lock.sh HOST [on|off|status]
#
# on (the default) holds a system inhibitor for sleep, idle and the lid switch
# (passwordless sudo on HOST) and, once the graphical session is up, an idle
# inhibitor inside it: Cinnamon's idle suspend honours only the session's own,
# and systemd-inhibit from an SSH login is refused. Neither survives a reboot,
# so run it again after one. off releases both; status shows them.
set -euo pipefail

usage() { echo "usage: $0 HOST [on|off|status]" >&2; exit 2; }
if [ $# -lt 1 ] || [ $# -gt 2 ]; then usage; fi
host=$1 action=${2:-on}

status() {
  ssh "$host" 'echo "system lock:  $(systemctl is-active claude-awake-sys)"
    echo "session lock: $(systemctl --user is-active claude-awake)"
    echo "session idle inhibited: $(busctl --user call org.gnome.SessionManager /org/gnome/SessionManager \
      org.gnome.SessionManager IsInhibited u 4 2>/dev/null || echo "no session")"'
}

case $action in
  on)
    ssh "$host" 'systemctl is-active -q claude-awake-sys ||
      sudo -n systemd-run -q --unit=claude-awake-sys -p IgnoreOnIsolate=yes \
        systemd-inhibit --what=sleep:idle:handle-lid-switch --who=claude "--why=Claude is working" sleep infinity' ||
      echo "no system lock: sudo on $host asks for a password" >&2
    for _ in $(seq 60); do
      ssh "$host" 'busctl --user status org.gnome.SessionManager >/dev/null 2>&1' && break
      sleep 10
    done
    # Inhibit flag 12 = suspend (4) + idle (8).
    ssh "$host" 'systemctl --user is-active -q claude-awake ||
      systemd-run --user -q --unit=claude-awake --collect python3 -c "
from gi.repository import Gio, GLib
b = Gio.bus_get_sync(Gio.BusType.SESSION)
b.call_sync(\"org.gnome.SessionManager\", \"/org/gnome/SessionManager\", \"org.gnome.SessionManager\",
            \"Inhibit\", GLib.Variant(\"(susu)\", (\"claude\", 0, \"Claude is working\", 12)), None, 0, -1, None)
GLib.MainLoop().run()"
      for _ in $(seq 20); do
        busctl --user call org.gnome.SessionManager /org/gnome/SessionManager \
          org.gnome.SessionManager IsInhibited u 4 | grep -q true && break
        sleep 0.5
      done'
    status
    ;;
  off)
    ssh "$host" 'systemctl --user stop claude-awake 2>/dev/null; sudo -n systemctl stop claude-awake-sys 2>/dev/null; true'
    status
    ;;
  status) status ;;
  *) usage ;;
esac
