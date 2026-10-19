"""Core of the browser tests: a throwaway Brave driven over the DevTools
protocol, the local test pages, screen reads and input on X11, and the GPU
errors in the kernel log. wayland.py replaces the X11 parts."""
import atexit, base64, ctypes, ctypes.util, glob, json, os, re, socket, struct, subprocess, sys, time, urllib.request, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
STATE = os.environ.get("BT_STATE", os.path.join(REPO, "work", "browser-test"))
PROFILE = os.path.join(STATE, "profile")
XDG_DATA = os.path.join(STATE, "xdg-data")
RESULTS = os.path.join(STATE, "results")
MEDIA = os.path.join(STATE, "media")
BRAVE = os.environ.get("BT_BRAVE", "/opt/brave.com/brave/brave")
PORT = 9333
WEB_PORT = 8765
WEB = f"http://127.0.0.1:{WEB_PORT}"
UNIT, WEB_UNIT = "browser-test", "browser-test-www"
CLIPS = os.environ.get("CLIPS", "media/h264-1080.mp4,media/vp9-1080.webm,media/h264-720.mp4").split(",")
GPU_ERRORS = re.compile(r"nouveau .*(DMA_PUSHER|DATA_ERROR|ILLEGAL_MTHD|CACHE_ERROR|TLB flush|fault|timeout)"
                        r"|NVRM: Xid|amdgpu.*(timeout|fault|GPU reset)|i915.*(GPU HANG|reset)")


def screen_size():
    """The connected output's preferred mode, from DRM."""
    for c in sorted(glob.glob("/sys/class/drm/card*-*")):
        try:
            if open(c + "/status").read().strip() == "connected":
                w, h = open(c + "/modes").readline().strip().split("x")
                return int(w), int(h)
        except (OSError, ValueError):
            pass
    return 1920, 1080


SCREEN_W, SCREEN_H = screen_size()
MENU_X = SCREEN_W - 22  # the main menu button, top right


def page(name):
    """A test page's URL; BT_LOG=1 adds the scrolling log panel."""
    return f"{WEB}/{name}.html" + ("?log" if os.environ.get("BT_LOG") else "")


# --- DevTools protocol over a minimal websocket client ---------------------
class CDP:
    def __init__(self, ws_url):
        host, rest = ws_url[len("ws://"):].split("/", 1)
        h, p = host.split(":")
        self.s = socket.create_connection((h, int(p)), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET /{rest} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
                        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                        "Sec-WebSocket-Version: 13\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.s.recv(4096)
        self.buf = buf.split(b"\r\n\r\n", 1)[1]
        self.id = 0
        self.events = []

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise ConnectionError("CDP closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _frame(self):
        data = b""
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            data += self._read(n)
            if b0 & 0x80:
                return data

    def send(self, method, params=None, timeout=30):
        self.id += 1
        msg = json.dumps({"id": self.id, "method": method, "params": params or {}}).encode()
        mask = os.urandom(4)
        n = len(msg)
        hdr = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else
                               bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else
                               bytes([0x80 | 127]) + struct.pack(">Q", n))
        self.s.sendall(hdr + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(msg)))
        end = time.time() + timeout
        while time.time() < end:
            m = json.loads(self._frame())
            if m.get("id") == self.id:
                return m.get("result", m.get("error"))
            self.events.append(m)
        raise TimeoutError(method)

    def pump(self, seconds):
        self.s.settimeout(0.2)
        end = time.time() + seconds
        while time.time() < end:
            try:
                self.events.append(json.loads(self._frame()))
            except (socket.timeout, TimeoutError):
                pass
        self.s.settimeout(30)

    def js(self, expr):
        r = self.send("Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": True})
        return r.get("result", {}).get("value")


def targets():
    return [t for t in json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json", timeout=5))
            if t["type"] == "page"]


def current_cdp():
    """The most recently active tab (DevTools lists it first)."""
    return CDP(targets()[0]["webSocketDebuggerUrl"])


# --- X11: screen reads (xwd) and XTest input --------------------------------
def screen():
    raw = subprocess.run(["xwd", "-root", "-silent"], capture_output=True, check=True).stdout
    f = struct.unpack(">25I", raw[:100])
    hsize, w, h, bpp, bpl, ncolors = f[0], f[4], f[5], f[11], f[12], f[19]
    return w, h, bpl, bpp // 8, raw[hsize + ncolors * 12:]


def region_stats(shot, x0, y0, x1, y1, step=8):
    """White, black and mean colour of a screen region given in fractions."""
    w, h, bpl, bypp, px = shot
    white = black = n = rs = gs = bs = 0
    sig = []
    for y in range(int(y0 * h), int(y1 * h), step):
        for x in range(int(x0 * w), int(x1 * w), step):
            o = y * bpl + x * bypp
            b, g, r = px[o], px[o + 1], px[o + 2]
            n += 1; rs += r; gs += g; bs += b
            white += r > 235 and g > 235 and b > 235
            black += r < 20 and g < 20 and b < 20
            sig.append((r >> 4, g >> 4, b >> 4))
    return {"white": white / n, "black": black / n, "mean": (rs // n, gs // n, bs // n), "sig": sig}


def region(shot, x0, y0, x1, y1):
    """A screen region given in fractions: width, height, bytes per pixel and
    the pixels, row by row, in the backend's channel order."""
    w, h, bpl, bypp, px = shot
    X0, X1 = int(x0 * w), int(x1 * w)
    rows = [px[y * bpl + X0 * bypp:y * bpl + X1 * bypp] for y in range(int(y0 * h), int(y1 * h))]
    return X1 - X0, len(rows), bypp, b"".join(rows)


def cell_means(reg, cells=16, step=4):
    """Mean colour of each cell of a cells x cells grid over a region."""
    w, h, bpp, px = reg
    out = []
    for cy in range(cells):
        for cx in range(cells):
            n = c0 = c1 = c2 = 0
            for y in range(cy * h // cells, (cy + 1) * h // cells, step):
                for x in range(cx * w // cells, (cx + 1) * w // cells, step):
                    o = (y * w + x) * bpp
                    c0 += px[o]; c1 += px[o + 1]; c2 += px[o + 2]; n += 1
            out.append((c0 // n, c1 // n, c2 // n))
    return out


_X = {}


def _xlib():
    if not _X:
        x11 = ctypes.CDLL(ctypes.util.find_library("X11"))
        x11.XOpenDisplay.restype = ctypes.c_void_p
        x11.XStringToKeysym.restype = ctypes.c_ulong
        _X.update(x11=x11, xtst=ctypes.CDLL(ctypes.util.find_library("Xtst")),
                  dpy=ctypes.c_void_p(x11.XOpenDisplay(None)))
    return _X["x11"], _X["xtst"], _X["dpy"]


def move(x, y):
    x11, xtst, d = _xlib()
    xtst.XTestFakeMotionEvent(d, -1, x, y, 0)
    x11.XFlush(d)


def click(x, y, button=1):
    x11, xtst, d = _xlib()
    xtst.XTestFakeMotionEvent(d, -1, x, y, 0)
    x11.XFlush(d)
    time.sleep(0.05)
    xtst.XTestFakeButtonEvent(d, button, 1, 0)
    xtst.XTestFakeButtonEvent(d, button, 0, 0)
    x11.XFlush(d)


def keys(*names):
    """Press the keys in order and release them in reverse (Control_L t)."""
    x11, xtst, d = _xlib()
    codes = [x11.XKeysymToKeycode(d, x11.XStringToKeysym(n.encode())) for n in names]
    for c in codes:
        xtst.XTestFakeKeyEvent(d, c, 1, 0)
    for c in reversed(codes):
        xtst.XTestFakeKeyEvent(d, c, 0, 0)
    x11.XFlush(d)


def click_at(xf, yf):
    click(int(xf * SCREEN_W), int(yf * SCREEN_H))


def colour():
    """The page colour in the middle of the screen: red, blue, green or r,g,b."""
    r, g, b = region_stats(screen(), 0.45, 0.5, 0.55, 0.6, step=16)["mean"]
    for name, (cr, cg, cb) in {"red": (255, 0, 0), "blue": (0, 0, 255), "green": (0, 128, 0)}.items():
        if abs(r - cr) < 60 and abs(g - cg) < 60 and abs(b - cb) < 60:
            return name
    return f"{r},{g},{b}"


def session_env():
    return {"DISPLAY": os.environ.get("DISPLAY", ":0"),
            "XAUTHORITY": os.environ.get("XAUTHORITY", os.path.expanduser("~/.Xauthority"))}


def browser_flags():
    return []


# --- staying awake -----------------------------------------------------------
_INHIBITORS = []


def inhibit():
    """Keep the machine from suspending or going idle until this process ends:
    through the desktop's session manager, which also works from an SSH login,
    or else through logind, which allows it only from the local session."""
    try:
        from gi.repository import Gio, GLib
        bus = Gio.bus_get_sync(Gio.BusType.SESSION)
        bus.call_sync("org.gnome.SessionManager", "/org/gnome/SessionManager", "org.gnome.SessionManager",
                      "Inhibit", GLib.Variant("(susu)", ("browser-test", 0, "a browser test is running", 4 | 8)),
                      None, 0, -1, None)
        _INHIBITORS.append(bus)  # the inhibitor lasts as long as this connection
        return
    except Exception:  # no GObject bindings or no session manager
        pass
    p = subprocess.Popen(["systemd-inhibit", "--what=sleep:idle", "--who=browser-test",
                          "--why=a browser test is running", "sleep", "infinity"], stderr=subprocess.PIPE)
    time.sleep(0.5)
    if p.poll() is not None:
        print("browser-test: cannot hold off suspend:", p.stderr.read().decode().strip(), file=sys.stderr)
        return
    _INHIBITORS.append(p)
    atexit.register(p.terminate)


# --- the kernel log ----------------------------------------------------------
def gpu_errors():
    """GPU error lines in this boot's kernel log, or None if it is unreadable."""
    r = subprocess.run(["journalctl", "-k", "-b", "-o", "cat", "--no-pager"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout:
        return None
    return [line for line in r.stdout.splitlines() if GPU_ERRORS.search(line)]


# --- the test server and the browser ----------------------------------------
def serve():
    """Start the page server unless it is up: www/ here, media/ from STATE."""
    try:
        urllib.request.urlopen(f"{WEB}/red.html", timeout=2)
        return
    except OSError:
        pass
    subprocess.run(["systemctl", "--user", "reset-failed", WEB_UNIT], capture_output=True)
    subprocess.run(["systemd-run", "--user", "--unit", WEB_UNIT, "--collect", "--quiet",
                    "python3", os.path.join(HERE, "serve.py"), str(WEB_PORT), os.path.join(HERE, "www"), MEDIA],
                   check=True)
    for _ in range(20):
        try:
            urllib.request.urlopen(f"{WEB}/red.html", timeout=2)
            return
        except OSError:
            time.sleep(0.25)
    raise RuntimeError("the page server did not start")


def seed_profile():
    """A fresh profile whose bookmarks bar shows one folder of test pages."""
    subprocess.run(["rm", "-rf", PROFILE])
    os.makedirs(os.path.join(PROFILE, "Default"))

    def node(**kw):
        return dict(kw, guid=str(uuid.uuid4()), date_added="13370000000000000", date_last_used="0")
    pages = [node(type="url", id=str(10 + i), name=f"Page {i}", url=page("red" if i % 2 else "blue"))
             for i in range(30)]
    bar = node(type="folder", id="1", name="Bookmarks bar", date_modified="0",
               children=[node(type="folder", id="5", name="Test folder", date_modified="0", children=pages)])
    roots = {"bookmark_bar": bar,
             "other": node(type="folder", id="2", name="Other bookmarks", date_modified="0", children=[]),
             "synced": node(type="folder", id="3", name="Mobile bookmarks", date_modified="0", children=[])}
    with open(os.path.join(PROFILE, "Default", "Bookmarks"), "w") as f:
        json.dump({"checksum": "", "roots": roots, "version": 1}, f)
    with open(os.path.join(PROFILE, "Default", "Preferences"), "w") as f:
        json.dump({"bookmark_bar": {"show_on_all_tabs": True}}, f)


def offline_flags():
    """Only 127.0.0.1 resolves unless BT_NETWORK=1, so web apps a browser policy
    installs into the test profile stay idle instead of loading and using CPU."""
    if os.environ.get("BT_NETWORK"):
        return []
    return ["--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"]


def cgroup_usec():
    cg = subprocess.run(["systemctl", "--user", "show", "-p", "ControlGroup", "--value", UNIT],
                        capture_output=True, text=True).stdout.strip()
    with open(f"/sys/fs/cgroup{cg}/cpu.stat") as f:
        return int(f.readline().split()[1])


def main_pid():
    return int(subprocess.run(["systemctl", "--user", "show", "-p", "MainPID", "--value", UNIT],
                              capture_output=True, text=True).stdout)


def stop():
    subprocess.run(["systemctl", "--user", "stop", UNIT], capture_output=True)


def start(env, flags):
    """Brave with a fresh profile on red.html; returns that tab's CDP."""
    serve()
    stop()
    subprocess.run(["systemctl", "--user", "reset-failed", UNIT], capture_output=True)
    seed_profile()
    cmd = ["systemd-run", "--user", "--unit", UNIT, "--collect", "--quiet"]
    # Web apps the browser policy installs write launchers and icons there, and
    # in the user's own data directory they would replace the real profile's.
    cmd += [f"--setenv={k}={v}" for k, v in {**session_env(), "XDG_DATA_HOME": XDG_DATA, **env}.items()]
    if os.environ.get("BT_STDERR"):
        cmd += ["-p", f"StandardError=truncate:{os.environ['BT_STDERR']}"]
    cmd += [BRAVE, f"--user-data-dir={PROFILE}", f"--remote-debugging-port={PORT}",
            "--no-first-run", "--no-default-browser-check", "--password-store=basic", "--disable-extensions",
            "--autoplay-policy=no-user-gesture-required", "--start-maximized", "--enable-logging=stderr",
            "--disable-features=BraveRewards,BraveNews", *offline_flags(), *browser_flags(), *flags, page("red")]
    subprocess.run(cmd, check=True)
    for _ in range(60):
        try:
            tabs = [t for t in targets() if "red.html" in t["url"]]
            if tabs:
                return CDP(tabs[0]["webSocketDebuggerUrl"])
        except OSError:
            pass
        time.sleep(0.5)
    raise RuntimeError("Brave did not open its debugging port")


def gpu_info():
    ver = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/version", timeout=5))
    gpu = CDP(ver["webSocketDebuggerUrl"]).send("SystemInfo.getInfo").get("gpu", {})
    feats = gpu.get("featureStatus", {})
    dec = [f'{p.get("profile")} {p.get("maxResolution", {}).get("width")}x{p.get("maxResolution", {}).get("height")}'
           for p in gpu.get("videoDecoding", [])]
    return {"features": {k: feats.get(k) for k in ("gpu_compositing", "video_decode", "webgl", "vulkan",
                                                    "rasterization")},
            "decode_profiles": dec,
            "gl_renderer": next((d.get("deviceString") for d in gpu.get("devices", []) if d.get("active")), None)}


def save(name, result):
    os.makedirs(RESULTS, exist_ok=True)
    path = os.path.join(RESULTS, name + ".json")
    with open(path, "w") as f:
        json.dump(result, f, indent=1)
    return path
