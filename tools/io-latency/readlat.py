#!/usr/bin/env python3
"""readlat.py FILE OUT — O_DIRECT 4 KiB random reads from FILE every 100 ms until SIGINT/SIGTERM;
the raw samples go to OUT as JSON."""
import json, mmap, os, random, signal, sys, time

path, out = sys.argv[1:3]
stop = []
for s in (signal.SIGINT, signal.SIGTERM):
    signal.signal(s, lambda *a: stop.append(1))
fd = os.open(path, os.O_RDONLY | os.O_DIRECT); blocks = os.fstat(fd).st_size // 4096
buf = mmap.mmap(-1, 4096); m0 = time.monotonic(); t0 = time.time(); lat = []
while not stop:
    s = time.monotonic(); os.preadv(fd, [buf], random.randrange(blocks) * 4096)
    lat.append((round(s - m0, 2), round((time.monotonic() - s) * 1000, 2)))
    time.sleep(max(0, 0.1 - (time.monotonic() - s)))
json.dump(dict(t0=t0, lat=lat), open(out, "w"))
