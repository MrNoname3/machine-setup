#!/usr/bin/env python3
"""analyze.py RESULTS... — one row per run: the desktop's fsync stalls and read latency, the jobs'
time, bytes and CPU, the disk's flush latency and write rate, and, from dstate.jsonl, how long the
desktop's threads sat blocked and on what. Also writes RESULTS/analysis.json.

stall_s is the time the probe spent inside fsyncs that took over 1 s. A percentile undercounts a
stall, because the probe takes no samples while it is stuck in one; this sum does not."""
import glob, json, os, statistics, sys
from collections import Counter

def pct(xs, p):
    xs = sorted(xs); return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else 0

def episodes(ts, gap=0.25):
    """Lengths (s) of runs of consecutive 100 ms samples."""
    out, start, prev = [], None, None
    for t in sorted(ts):
        if prev is None or t - prev > gap:
            if start is not None: out.append(prev - start + 0.1)
            start = t
        prev = t
    if start is not None: out.append(prev - start + 0.1)
    return out

def run(d, dstate):
    meta = json.load(open(f"{d}/meta.json"))
    if "aborted" in meta:
        return dict(run=os.path.basename(d.rstrip("/")), aborted=meta["aborted"])
    a, b = meta["t_start"], meta["t_end"]
    pr = json.load(open(f"{d}/probe.json")); rd = json.load(open(f"{d}/readlat.json"))
    lat = [l / 1000 for t, l in pr["lat"] if a <= pr["t0"] + t <= b]
    reads = [l for t, l in rd["lat"] if a <= rd["t0"] + t <= b]
    sec = [dict(zip(pr["sec_fields"], r)) for r in pr["sec"] if a <= pr["t0"] + r[0] <= b]
    flush = [s["disk_flush_ms"] for s in sec if s["disk_flushes"]]
    jobs = [json.load(open(x)) for x in sorted(glob.glob(f"{d}/jobs/job*.json"))]
    r = dict(run=os.path.basename(d.rstrip("/")),
             fsync_max=max(lat), fsync_p99=pct(lat, .99), stall_s=sum(l for l in lat if l > 1),
             stalls_2s=sum(l > 2 for l in lat), read_p99_ms=pct(reads, .99), read_max_ms=max(reads, default=0),
             job_s=statistics.mean(j["end"] - j["start"] for j in jobs) if jobs else 0,
             written_gb=meta["jobs_written"] / 1e9 if meta["jobs_written"] is not None else None,
             fs_gb=meta["fs_written"] / 1e9, cpu_s=meta["cpu_busy_s"],
             flush_ms_p50=pct(flush, .5), flush_ms_max=max(flush, default=0),
             disk_mbps=statistics.mean(s["disk_write_mbps"] for s in sec) if sec else 0,
             kwin=meta["kwin_hangs"])
    if dstate is not None:
        rows = [x for x in dstate if a <= x["t"] <= b]
        km = [x for x in rows if x["proc"] == "kwin_wayland" and x["main"]]
        ep = episodes([x["t"] for x in km])
        r.update(kwin_main_s=round(len(km) * 0.1, 1), kwin_main_longest=round(max(ep), 1) if ep else 0,
                 blocked_s={k: round(v * 0.1, 1) for k, v in Counter(x["proc"] for x in rows).most_common(5)},
                 stacks=Counter(f"{x['proc']}/{x['comm']}: " + " < ".join(x["stack"][:5])
                                for x in rows).most_common(3),
                 synced=Counter(f"{x['proc']}: {x['file']}" for x in rows if x.get("file")).most_common(3))
    return r

COLS = ["run", "fsync_max", "fsync_p99", "stall_s", "stalls_2s", "read_p99_ms", "job_s", "written_gb",
        "fs_gb", "cpu_s", "flush_ms_max", "disk_mbps", "kwin", "kwin_main_s"]

for root in sys.argv[1:]:
    ds = None
    if os.path.exists(f"{root}/dstate.jsonl"):
        ds = [json.loads(l) for l in open(f"{root}/dstate.jsonl") if l.strip()]
    rows = [run(d, ds) for d in sorted(glob.glob(f"{root}/*/")) if os.path.exists(f"{d}/meta.json")]
    json.dump(rows, open(f"{root}/analysis.json", "w"), indent=1)
    print(f"== {root}")
    print("\t".join(COLS))
    for r in rows:
        if "aborted" in r:
            print(f"{r['run']}\tABORTED: {r['aborted']}"); continue
        print("\t".join(f"{r[c]:.2f}" if isinstance(r.get(c), float) else str(r.get(c) if r.get(c) is not None else "-")
                        for c in COLS))
    for r in rows:
        if r.get("blocked_s"):
            print(f"  {r['run']}: blocked {r['blocked_s']}")
            for s, n in r["stacks"] + r["synced"]:
                print(f"    x{n} {s}")
