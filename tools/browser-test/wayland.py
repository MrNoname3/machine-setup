"""Wayland backend: importing it replaces browser_test's X11 screen reads and
XTest input with Cinnamon's area screenshot over D-Bus and the virtual
devices of uinputd.py, and starts Brave as a native Wayland client."""
import os, socket, struct, subprocess, tempfile, time, zlib
import browser_test as bt

os.environ.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path=/run/user/{os.getuid()}/bus")
SOCK = "/var/tmp/uinputd.sock"


def _send(cmd):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(SOCK)
    except OSError as e:
        raise RuntimeError(f"no {SOCK}: start uinputd.py as root first") from e
    s.sendall((cmd + "\n").encode())
    s.recv(16)
    s.close()


def _png_rgb(data):
    pos, chunks, w, h, ct = 8, b"", 0, 0, 2
    while pos < len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if typ == b"IHDR":
            w, h, _, ct = struct.unpack(">IIBB", body[:10])
        elif typ == b"IDAT":
            chunks += body
        pos += 12 + n
    bpp = 4 if ct == 6 else 3
    raw, stride = zlib.decompress(chunks), w * bpp
    out, prev, i = bytearray(), bytearray(stride), 0
    for _ in range(h):
        f, line = raw[i], bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b, c = prev[x], prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line
        prev = line
    return w, h, bpp, out


def area(x, y, w, h):
    fn = tempfile.mktemp(suffix=".png", dir="/var/tmp")
    subprocess.run(["busctl", "--user", "call", "org.Cinnamon", "/org/Cinnamon", "org.Cinnamon", "ScreenshotArea",
                    "biiiibs", "false", str(x), str(y), str(w), str(h), "false", fn], check=True, capture_output=True)
    data = b""
    for _ in range(250):  # Cinnamon writes the file after the call returns
        if os.path.exists(fn):
            with open(fn, "rb") as f:
                data = f.read()
            if data.endswith(b"IEND\xaeB`\x82"):
                break
        time.sleep(0.02)
    else:
        raise RuntimeError("no screenshot from Cinnamon")
    os.unlink(fn)
    return _png_rgb(data)


def region_stats(_shot, x0, y0, x1, y1, step=8):
    W, H = bt.SCREEN_W, bt.SCREEN_H
    w, h, bpp, px = area(int(x0 * W), int(y0 * H), int((x1 - x0) * W), int((y1 - y0) * H))
    white = black = n = rs = gs = bs = 0
    sig = []
    for yy in range(0, h, step):
        for xx in range(0, w, step):
            o = (yy * w + xx) * bpp
            r, g, b = px[o], px[o + 1], px[o + 2]
            n += 1; rs += r; gs += g; bs += b
            white += r > 235 and g > 235 and b > 235
            black += r < 20 and g < 20 and b < 20
            sig.append((r >> 4, g >> 4, b >> 4))
    return {"white": white / n, "black": black / n, "mean": (rs // n, gs // n, bs // n), "sig": sig}


bt.screen = lambda: None
bt.region_stats = region_stats
bt.move = lambda x, y: _send(f"move {x} {y}")
bt.click = lambda x, y, button=1: _send(f"click {x} {y} {button}")
bt.keys = lambda *names: _send("keys " + " ".join(names))
bt.session_env = lambda: {"WAYLAND_DISPLAY": os.environ.get("WAYLAND_DISPLAY", "wayland-0"),
                          "XDG_SESSION_TYPE": "wayland"}
bt.browser_flags = lambda: [] if os.environ.get("BT_NO_OZONE") else ["--ozone-platform=wayland"]
