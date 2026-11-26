#!/usr/bin/env python3
"""Mixed-up fields in Brave's video, measured in the page:

  combing.py NAME ROUNDS [--env K=V ...] [-- BRAVE_FLAGS...]

Opens one of CLIPS ROUNDS times and plays it for 2-4 s. A script in the page
draws every presented frame onto a canvas at its own size and scores its
combing: the mean of |2*row(y) - row(y-1) - row(y+1)| over the luma, minus the
same with rows two apart. A whole picture scores around zero or below; one
whose two fields come from different pictures scores in the tens or more.
Prints the rounds far above the median and saves every round's highest score
into results/combing-NAME.json."""
import json, random, statistics, sys, time

sys.dont_write_bytecode = True
import browser_test as bt  # noqa: E402
import run  # noqa: E402  (its parse(), and the Wayland backend when in use)

PROBE = """(()=>{
const v=document.getElementById('v'), c=document.createElement('canvas');
const g=c.getContext('2d',{willReadFrequently:true});
window.__comb=[];
function score(){
  const W=v.videoWidth, H=v.videoHeight; if(!W) return;
  if(c.width!=W||c.height!=H){c.width=W;c.height=H;}
  g.drawImage(v,0,0);
  const d=g.getImageData(0,0,W,H).data, S=W*4; let a=0,b=0,n=0;
  for(let y=2;y<H-2;y++) for(let x=0;x<W;x+=8){
    const i=y*S+x*4, L=(j)=>d[j]*0.3+d[j+1]*0.59+d[j+2]*0.11;
    const m=L(i); a+=Math.abs(2*m-L(i-S)-L(i+S)); b+=Math.abs(2*m-L(i-2*S)-L(i+2*S)); n++;
  }
  window.__comb.push([v.currentTime,(a-b)/n]);
}
function tick(){ if(v.readyState>=2) score(); v.requestVideoFrameCallback(tick); }
v.requestVideoFrameCallback(tick);
return 1})()"""


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    name, rounds = sys.argv[1], int(sys.argv[2])
    env, flags = run.parse(sys.argv[3:])
    bt.inhibit()
    e0 = bt.gpu_errors()
    cdp = bt.start(env, flags)
    random.seed(3)
    rows, errors = [], []
    for n in range(rounds):
        clip = random.choice(bt.CLIPS)
        cdp.send("Page.navigate", {"url": f"{bt.WEB}/video.html?src={clip}"})
        time.sleep(0.3)
        cdp.js(PROBE)
        time.sleep(random.uniform(2.0, 4.0))
        scores = json.loads(cdp.js("JSON.stringify(window.__comb||[])") or "[]")
        cdp.send("Page.navigate", {"url": f"{bt.WEB}/red.html"})
        time.sleep(0.5)
        top = max(scores, key=lambda s: s[1]) if scores else [0, 0]
        rows.append({"round": n, "clip": clip, "frames": len(scores), "at": top[0], "max": top[1]})
        errors = bt.gpu_errors()[len(e0):]
        if errors:
            break
    bt.stop()
    med = statistics.median(r["max"] for r in rows)
    bad = [r for r in rows if r["max"] > max(3 * med, med + 2)]
    print(f"{len(rows)} rounds, {sum(r['frames'] for r in rows)} frames scored, "
          f"median of round maxima {med:.2f}, {len(bad)} rounds far above it")
    for r in bad:
        print(f"  round {r['round']} {r['clip']}: max {r['max']:.2f} at {r['at']:.2f} s")
    for e in errors[:4]:
        print("GPU error:", e)
    print(bt.save("combing-" + name, {"env": env, "flags": flags, "rounds": rows, "gpu_errors": errors}))


if __name__ == "__main__":
    main()
