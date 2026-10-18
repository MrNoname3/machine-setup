"""Freeze hunt: real input on a test Brave until its picture stops following
or the kernel logs a GPU error. Each round does one action from ACTIONS and
then reads the page colour in the middle of the screen."""
import ctypes, os, random, subprocess, time
import browser_test as bt

# focus and minimise need X11 window management; the others work on Wayland too.
ALL = ["click", "newtab", "switch", "close", "focus", "minimise", "context", "appmenu", "menuclick",
       "select", "tooltip", "bookmarks"]
DEFAULT = "click,click,newtab,switch,focus,minimise,close,context,appmenu,tooltip,bookmarks"


class XClientMessage(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                ("format", ctypes.c_int), ("data", ctypes.c_long * 5), ("pad", ctypes.c_long * 12)]


def wm_message(win, atom, *data):
    x11, _, d = bt._xlib()
    x11.XInternAtom.restype = ctypes.c_ulong
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    ev = XClientMessage(type=33, send_event=1, display=d, window=win,
                        message_type=x11.XInternAtom(d, atom.encode(), 0), format=32)
    for i, v in enumerate(data):
        ev.data[i] = v
    x11.XSendEvent(d, x11.XDefaultRootWindow(d), 0, (1 << 20) | (1 << 19), ctypes.byref(ev))
    x11.XFlush(d)


def x_windows():
    """(window, pid, class) of the X clients the window manager lists."""
    out = subprocess.run(["xprop", "-root", "_NET_CLIENT_LIST"], capture_output=True, text=True).stdout
    ids = [int(w.strip().rstrip(","), 16) for w in out.split("#")[1].split(",")] if "#" in out else []
    res = []
    for w in ids:
        p = subprocess.run(["xprop", "-id", hex(w), "_NET_WM_PID", "WM_CLASS"], capture_output=True, text=True).stdout
        pid = next((int(line.split("=")[1]) for line in p.splitlines() if line.startswith("_NET_WM_PID")), 0)
        res.append((w, pid, p.split("WM_CLASS")[-1].strip()))
    return res


def colour():
    """bt.colour(), or the reason there is no picture to read."""
    try:
        return bt.colour()
    except RuntimeError as e:  # a stalled compositor counts as a picture that does not follow
        return str(e)


def wait_for(expect, seconds=3.0):
    end = time.time() + seconds
    seen = None
    while time.time() < end:
        time.sleep(0.25)
        seen = colour()
        if seen == expect:
            return True, seen
    return False, seen


def run(name, minutes, env, flags, wayland):
    actions = os.environ.get("ACTIONS", DEFAULT).split(",")
    unknown = set(actions) - set(ALL)
    if unknown:
        raise SystemExit(f"unknown actions: {', '.join(sorted(unknown))}")
    if wayland:
        actions = [a for a in actions if a not in ("focus", "minimise")]
    errors0 = bt.gpu_errors()
    cdp = bt.start(env, flags)
    time.sleep(3)
    brave, others = None, []
    if not wayland:
        pid = bt.main_pid()
        wins = x_windows()
        brave = next((w for w, p, _ in wins if p == pid), None)
        others = [w for w, p, c in wins if p != pid and "panel" not in c.lower() and "desktop" not in c.lower()]
    log, tabs, cur = [], 1, "red"
    end, n = time.time() + minutes * 60, 0
    random.seed(1)
    result = {"name": name, "env": env, "flags": flags, "wayland": wayland, "frozen": False,
              "gpu_errors": None if errors0 is None else []}
    while time.time() < end:
        n += 1
        act = random.choice(actions)
        if act == "close" and tabs < 3:
            act = "click"
        if act == "click":
            bt.click_at(0.5, 0.55)
            cur = {"red": "blue", "blue": "red"}.get(cur, "red")
        elif act == "newtab":
            bt.keys("Control_L", "t")
            time.sleep(1.5)
            new = [t for t in bt.targets() if not t["url"].startswith(bt.WEB)]
            if new:
                cdp = bt.CDP(new[0]["webSocketDebuggerUrl"])
                cdp.send("Page.navigate", {"url": bt.page("red")})
            tabs += 1
            cur = "red"
        elif act == "switch":
            bt.keys("Control_L", "Tab")
            time.sleep(0.8)
            cur = None
        elif act == "close":
            bt.keys("Control_L", "w")
            tabs -= 1
            time.sleep(0.8)
            cur = None
        elif act == "focus" and brave and others:
            wm_message(random.choice(others), "_NET_ACTIVE_WINDOW", 2, 0, 0)
            time.sleep(1.0)
            wm_message(brave, "_NET_ACTIVE_WINDOW", 2, 0, 0)
            time.sleep(0.5)
        elif act == "minimise" and brave:
            wm_message(brave, "WM_CHANGE_STATE", 3)
            time.sleep(1.0)
            wm_message(brave, "_NET_ACTIVE_WINDOW", 2, 0, 0)
        elif act == "menuclick":
            bt.click(bt.MENU_X, 58)
            time.sleep(1.0)
            bt.keys("Escape")
            time.sleep(0.5)
        elif act == "appmenu":
            bt.keys("Alt_L", "f")
            time.sleep(1.0)
            bt.keys("Escape")
        elif act == "context":
            bt.click(bt.SCREEN_W // 2, bt.SCREEN_H // 2, 3)
            time.sleep(1.0)
            bt.keys("Escape")
        elif act == "select":
            cdp = bt.current_cdp()
            cdp.send("Page.navigate", {"url": bt.page("sel5")})
            time.sleep(1.5)
            bt.click(330, 190)
            time.sleep(1.0)
            bt.keys("Escape")
            time.sleep(0.5)
            cdp.send("Page.navigate", {"url": bt.page("red")})
            time.sleep(1.0)
            cur = "red"
        elif act == "tooltip":
            bt.move(20 + random.randint(0, 3) * 32, 60)
            time.sleep(2.0)
            bt.move(bt.SCREEN_W // 2, bt.SCREEN_H // 2)
        elif act == "bookmarks":
            # Shift+Alt+B focuses the bookmarks bar's first item, Brave's tab
            # groups button; the test folder comes after it.
            bt.keys("Shift_L", "Alt_L", "b")
            time.sleep(0.5)
            bt.keys("Right")
            time.sleep(0.2)
            bt.keys("space")
            time.sleep(1.0)
            if random.random() < 0.5:  # open its first page, a blue one
                bt.keys("Down")
                time.sleep(0.2)
                bt.keys("Return")
                cur = "blue"
            else:
                bt.keys("Escape")
                time.sleep(0.3)
                bt.keys("Escape")
        if cur is None:  # after a tab change only the screen knows the colour; read it twice
            time.sleep(1.0)
            a = colour()
            time.sleep(1.0)
            cur = colour()
            ok = a == cur and cur in ("red", "blue")
            seen = cur
            if not ok:  # a click must still turn a red or blue page to the other colour
                bt.click_at(0.5, 0.55)
                ok, seen = wait_for("blue" if a == "red" else "red", 3)
                cur = seen
        else:
            ok, seen = wait_for(cur, 3)
        log.append((n, act, cur, seen, ok))
        if not ok:
            ok, seen = wait_for(cur, 4)
            if not ok:
                result.update(frozen=True, round=n, action=act, expected=cur, seen=seen)
                try:
                    result["page_says"] = bt.current_cdp().js("location.pathname")
                except Exception as e:  # the page may be gone with the GPU process
                    result["page_says"] = repr(e)
                diag = os.path.join(bt.HERE, "freeze-diag.sh")
                result["diag"] = subprocess.run(["sudo", "-n", "sh", diag, bt.RESULTS], capture_output=True,
                                                text=True).stdout.strip()
        errors = bt.gpu_errors()
        if errors0 is not None and errors is not None and len(errors) > len(errors0):
            result["gpu_errors"] = [(n, act, line) for line in errors[len(errors0):]]
            result.setdefault("round", n)
            result.setdefault("action", act)
        if result["frozen"] or result["gpu_errors"]:
            break
    result["rounds"] = n
    result["log_tail"] = log[-12:]
    path = bt.save(f"stress-{name}", result)
    if not (result["frozen"] or result["gpu_errors"]):
        bt.stop()
    return result, path
