#!/usr/bin/env python3
"""probe.py OUT FSDEV DISK — the desktop side, until SIGINT/SIGTERM: a 4 KiB write + fsync next
to OUT every 100 ms, plus per second the I/O and CPU pressure (PSI), the write latency of the
filesystem's device FSDEV and of the physical DISK, and DISK's flush latency and write rate
(kernel names, e.g. dm-0 and nvme0n1). Writes the raw samples to OUT as JSON."""
import json, os, signal, sys, time

out, fsdev, disk = sys.argv[1:4]
path = os.path.join(os.path.dirname(os.path.abspath(out)), "probe.dat")
buf = os.urandom(4096)
stop = []
for s in (signal.SIGINT, signal.SIGTERM):
    signal.signal(s, lambda *a: stop.append(1))

def psi(kind):
    d = {}
    for line in open(f"/proc/pressure/{kind}"):
        f = line.split(); d[f[0]] = int(f[-1].split("=")[1])
    return d

def dstat(dev):
    f = open(f"/sys/block/{dev}/stat").read().split()
    # writes completed, write ms, in flight, flushes completed, flush ms, sectors written
    return int(f[4]), int(f[7]), int(f[8]), int(f[15]), int(f[16]), int(f[6])

m0 = time.monotonic(); t0 = time.time()
lat, sec = [], []
last = m0; p_io, p_cpu = psi("io"), psi("cpu"); p_dev = {d: dstat(d) for d in (disk, fsdev)}
while not stop:
    s = time.monotonic()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
    os.pwrite(fd, buf, 0); os.fsync(fd); os.close(fd)
    e = time.monotonic()
    lat.append((round(s - m0, 2), round((e - s) * 1000, 2)))
    if e - last >= 1.0:
        n_io, n_cpu = psi("io"), psi("cpu"); span = (e - last) * 1e6
        row = [round(e - m0, 1), 100 * (n_io["some"] - p_io["some"]) / span,
               100 * (n_io["full"] - p_io["full"]) / span, 100 * (n_cpu["some"] - p_cpu["some"]) / span]
        for d in (disk, fsdev):
            n = dstat(d); dw = n[0] - p_dev[d][0]
            row += [(n[1] - p_dev[d][1]) / dw if dw else 0, n[2]]
            if d == disk:
                df = n[3] - p_dev[d][3]
                row += [df, (n[4] - p_dev[d][4]) / df if df else 0, (n[5] - p_dev[d][5]) * 512 / span]
            p_dev[d] = n
        sec.append(row); p_io, p_cpu, last = n_io, n_cpu, e
    time.sleep(max(0, 0.1 - (time.monotonic() - s)))
json.dump(dict(t0=t0, lat=lat, sec=sec,
               sec_fields=["t", "io_some", "io_full", "cpu_some", "disk_wlat_ms", "disk_inflight",
                           "disk_flushes", "disk_flush_ms", "disk_write_mbps", "fs_wlat_ms", "fs_inflight"]),
          open(out, "w"))
