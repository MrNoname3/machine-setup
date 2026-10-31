#!/usr/bin/env python3
"""dstate.py OUT — as root, until SIGINT/SIGTERM: every 100 ms, record each thread of the desktop's
processes that sits in D state (uninterruptible sleep, nearly always waiting for I/O) with its
kernel stack, and for a thread inside fsync or fdatasync the file it syncs. One JSON line per
blocked thread per sample. The process names watched come from IOTEST_WATCH (comma-separated)."""
import json, os, signal, sys, time

WATCH = set(os.environ.get("IOTEST_WATCH") or
            "kwin_wayland,plasmashell,Xwayland,ksmserver,kded6,cinnamon,Xorg,nemo,brave,firefox,konsole".split(","))
out = open(sys.argv[1], "a", buffering=1)
stop = []
for s in (signal.SIGINT, signal.SIGTERM):
    signal.signal(s, lambda *a: stop.append(1))

def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None

pids, listed = [], 0.0
while not stop:
    now = time.time()
    if now - listed > 2:
        pids = [p for p in os.listdir("/proc") if p.isdigit() and (read(f"/proc/{p}/comm") or "").strip() in WATCH]
        listed = now
    for pid in pids:
        try:
            tids = os.listdir(f"/proc/{pid}/task")
        except OSError:
            continue
        for tid in tids:
            st = read(f"/proc/{pid}/task/{tid}/stat")
            if not st:
                continue
            r = st.rfind(")")
            if st[r + 2] != "D":
                continue
            stack = (read(f"/proc/{pid}/task/{tid}/stack") or "").splitlines()
            frames = [l.split("] ", 1)[-1].split("+")[0] for l in stack]
            # x86-64 syscall numbers: fsync 74, fdatasync 75; the first argument is the fd
            sc, path = (read(f"/proc/{pid}/task/{tid}/syscall") or "").split(), None
            if len(sc) > 1 and sc[0] in ("74", "75"):
                try:
                    path = os.readlink(f"/proc/{pid}/fd/{int(sc[1], 16)}")
                except (OSError, ValueError):
                    pass
            out.write(json.dumps(dict(t=round(now, 2), pid=int(pid), tid=int(tid), main=pid == tid,
                                      proc=(read(f"/proc/{pid}/comm") or "").strip(),
                                      comm=st[st.find("(") + 1:r], stack=frames[:14], file=path)) + "\n")
    time.sleep(max(0, 0.1 - (time.time() - now)))
