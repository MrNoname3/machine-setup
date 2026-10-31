#!/usr/bin/env bash
# Get the attention of the user at this machine: a notification that stays
# until dismissed, a sound and three beeps on the PC speaker.
#
#   ./scripts/notify.sh TITLE TEXT
#
# Inside a Flatpak sandbox it runs itself on the host, where the sound theme
# and the speaker's input device are. The beeps need the input group.
set -uo pipefail

if [ $# -ne 2 ]; then echo "usage: $0 TITLE TEXT" >&2; exit 2; fi
if [ -e /.flatpak-info ]; then
  exec flatpak-spawn --host "$(realpath "$0")" "$@"
fi

notify-send -u critical -a Claude "$1" "$2"
for _ in 1 2 3; do
  paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null
  sleep 0.4
done
python3 -I - <<'PY'
import glob, struct, time
EV_SND, SND_TONE = 0x12, 0x02
for dev in glob.glob("/dev/input/by-path/*pcspkr*"):
    try:
        with open(dev, "wb", buffering=0) as f:
            for _ in range(3):
                for hz, pause in ((2500, 0.3), (0, 0.2)):
                    f.write(struct.pack("llHHi", 0, 0, EV_SND, SND_TONE, hz))
                    time.sleep(pause)
    except OSError:
        pass
PY
