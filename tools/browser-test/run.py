#!/usr/bin/env python3
"""Hardware video decoding and freezes in Brave, on X11 or on Cinnamon's
Wayland session (chosen by XDG_SESSION_TYPE, or BT_WAYLAND=1/0):

  run.py video NAME [--env K=V ...] [-- BRAVE_FLAGS...]
  run.py quality SECONDS [--env K=V ...] [-- BRAVE_FLAGS...]
  run.py stress NAME MINUTES [--env K=V ...] [-- BRAVE_FLAGS...]

See README.md for what each one measures."""
import json, os, subprocess, sys, time

sys.dont_write_bytecode = True  # no __pycache__ beside the sources
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import browser_test as bt  # noqa: E402

WAYLAND = os.environ.get("BT_WAYLAND", "1" if os.environ.get("XDG_SESSION_TYPE") == "wayland" else "0") == "1"
if WAYLAND:
    import wayland  # noqa: E402,F401
import stress  # noqa: E402

QUALITY = ("(()=>{const v=document.getElementById('v'),q=v.getVideoPlaybackQuality();"
           "return [v.currentTime,q.totalVideoFrames,q.droppedVideoFrames]})()")


def parse(args):
    env, flags = {}, []
    while args and args[0] == "--env":
        k, v = args[1].split("=", 1)
        env[k] = v
        args = args[2:]
    if args and args[0] == "--":
        flags = args[1:]
    elif args:
        raise SystemExit(f"unexpected: {' '.join(args)}")
    return env, flags


def play(cdp, clip, settle):
    """Open the clip; the decoder Chromium picked and the errors it logged."""
    cdp.events.clear()
    cdp.send("Media.enable")
    cdp.send("Page.navigate", {"url": f"{bt.WEB}/{os.environ.get('BT_PAGE', 'video.html')}?src={clip}"})
    cdp.pump(settle)
    props, errors = {}, []
    for e in cdp.events:
        if e.get("method") == "Media.playerPropertiesChanged":
            for p in e["params"]["properties"]:
                props[p["name"]] = p["value"]
        elif e.get("method") == "Media.playerErrorsRaised":
            errors += [x.get("errorType", "") + " " + str(x.get("code", "")) for x in e["params"]["errors"]]
        elif e.get("method") == "Media.playerMessagesLogged":
            errors += [m["message"] for m in e["params"]["messages"] if m.get("level") in ("error", "warning")]
    return props.get("kVideoDecoderName"), props.get("kIsPlatformVideoDecoder"), errors


def video(name, env, flags):
    """Per clip: decoder, CPU of the whole browser, and a picture that is
    neither white nor black and moves."""
    res = {"name": name, "env": env, "flags": flags, "wayland": WAYLAND}
    cdp = bt.start(env, flags)
    time.sleep(3)
    try:
        res["gpu"] = bt.gpu_info()
        res["video"] = []
        for clip in bt.CLIPS:
            dec, platform, errors = play(cdp, clip, 6)
            t0, c0 = time.time(), bt.cgroup_usec()
            q0 = cdp.js(QUALITY)
            s1 = bt.region_stats(bt.screen(), 0.3, 0.35, 0.7, 0.75)
            time.sleep(5)
            s2 = bt.region_stats(bt.screen(), 0.3, 0.35, 0.7, 0.75)
            q1 = cdp.js(QUALITY)
            cpu = (bt.cgroup_usec() - c0) / 1e6 / (time.time() - t0) * 100
            res["video"].append({
                "clip": clip, "decoder": dec, "platform_decoder": platform, "errors": errors[:5],
                "cpu_pct": round(cpu), "white": round(s2["white"], 2), "black": round(s2["black"], 2),
                "moving": round(sum(a != b for a, b in zip(s1["sig"], s2["sig"])) / len(s1["sig"]), 2),
                "frames": q1[1] - q0[1] if q0 and q1 else None,
                "dropped": q1[2] - q0[2] if q0 and q1 else None})
    except Exception as e:  # keep what was measured
        res["error"] = repr(e)
    finally:
        bt.stop()
    path = bt.save(name, res)
    print(json.dumps({k: res.get(k) for k in ("name", "gpu", "error")}, indent=1))
    for v in res.get("video", []):
        print(v)
    print(path)


def quality(seconds, env, flags):
    """Per clip, without screen reads: frames shown and dropped, and the CPU of
    the browser and of the compositor (cinnamon on Wayland, Xorg on X11)."""
    comp = "cinnamon" if WAYLAND else "Xorg"
    cpid = subprocess.run(["pgrep", "-o", "-x", comp], capture_output=True, text=True).stdout.strip()

    def ticks():
        f = open(f"/proc/{cpid}/stat").read().rsplit(")", 1)[1].split()
        return int(f[11]) + int(f[12])
    cdp = bt.start(env, flags)
    time.sleep(3)
    hz = os.sysconf("SC_CLK_TCK")
    try:
        for clip in bt.CLIPS:
            dec, _, _ = play(cdp, clip, 4)
            q0, c0, k0, t0 = cdp.js(QUALITY), bt.cgroup_usec(), ticks(), time.time()
            time.sleep(seconds)
            q1, c1, k1, t1 = cdp.js(QUALITY), bt.cgroup_usec(), ticks(), time.time()
            dt = t1 - t0
            print(f"{clip:24s} {dec}: frames {q1[1] - q0[1]} dropped {q1[2] - q0[2]}  "
                  f"brave {100 * (c1 - c0) / 1e6 / dt:.0f}%  {comp} {100 * (k1 - k0) / hz / dt:.0f}%")
    finally:
        bt.stop()


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    bt.inhibit()
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "video":
        video(args[0], *parse(args[1:]))
    elif cmd == "quality":
        quality(float(args[0]), *parse(args[1:]))
    elif cmd == "stress" and len(args) >= 2:
        env, flags = parse(args[2:])
        result, path = stress.run(args[0], float(args[1]), env, flags, WAYLAND)
        print(json.dumps({k: v for k, v in result.items() if k != "log_tail"}, indent=1))
        print(path)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
