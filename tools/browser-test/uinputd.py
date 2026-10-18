#!/usr/bin/env python3
"""Root helper for Wayland: a virtual absolute pointer and keyboard on
/dev/uinput, driven over /var/tmp/uinputd.sock by the user whose uid is the
first argument, one command per line:
  click X Y [BUTTON]   move to the screen pixel and click (1 left, 3 right)
  move X Y
  keys NAME...         press in order, release in reverse (Control_L t)
It is kernel input, so it reaches Wayland clients as a real device would."""
import fcntl, os, socket, struct, sys, time

sys.dont_write_bytecode = True  # no __pycache__ beside the sources
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from browser_test import screen_size  # noqa: E402

W, H = screen_size()
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
BTN = {1: 0x110, 3: 0x111}
KEYS = {"Escape": 1, "Tab": 15, "Return": 28, "Control_L": 29, "Shift_L": 42, "Alt_L": 56, "space": 57,
        "F5": 63, "F10": 68, "F11": 87, "Up": 103, "Left": 105, "Right": 106, "Down": 108,
        "a": 30, "b": 48, "d": 32, "f": 33, "l": 38, "n": 49, "t": 20, "w": 17}
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT, UI_DEV_CREATE = 0x40045564, 0x40045565, 0x40045567, 0x5501
SOCK = "/var/tmp/uinputd.sock"

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
for ev in (EV_SYN, EV_KEY, EV_ABS):
    fcntl.ioctl(fd, UI_SET_EVBIT, ev)
for code in list(BTN.values()) + list(KEYS.values()):
    fcntl.ioctl(fd, UI_SET_KEYBIT, code)
for axis in (0, 1):
    fcntl.ioctl(fd, UI_SET_ABSBIT, axis)
absmax = [0] * 64
absmax[0], absmax[1] = W - 1, H - 1
dev = struct.pack("80sHHHHi", b"browser-test-input", 0x06, 0x1234, 0x5678, 1, 0)
dev += struct.pack("64i", *absmax) + struct.pack("64i", *[0] * 64) * 3
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(1)


def emit(t, c, v):
    os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))


def syn():
    emit(EV_SYN, 0, 0)


def move(x, y):
    emit(EV_ABS, 0, x)
    emit(EV_ABS, 1, y)
    syn()


def click(x, y, b=1):
    move(x, y)
    time.sleep(0.05)
    emit(EV_KEY, BTN[b], 1); syn(); time.sleep(0.05)
    emit(EV_KEY, BTN[b], 0); syn()


def keys(names):
    codes = [KEYS[n] for n in names]
    for c in codes:
        emit(EV_KEY, c, 1); syn(); time.sleep(0.03)
    for c in reversed(codes):
        emit(EV_KEY, c, 0); syn(); time.sleep(0.03)


if os.path.exists(SOCK):
    os.unlink(SOCK)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(SOCK)
os.chown(SOCK, int(sys.argv[1]) if len(sys.argv) > 1 else 0, -1)
os.chmod(SOCK, 0o600)
srv.listen(4)
while True:
    conn, _ = srv.accept()
    with conn:
        for line in conn.makefile():
            p = line.split()
            if not p:
                continue
            if p[0] == "click":
                click(int(p[1]), int(p[2]), int(p[3]) if len(p) > 3 else 1)
            elif p[0] == "move":
                move(int(p[1]), int(p[2]))
            elif p[0] == "keys":
                keys(p[1:])
            conn.sendall(b"ok\n")
