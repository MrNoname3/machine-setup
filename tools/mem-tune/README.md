# mem-tune — measuring a machine's memory

A small set of tools for answering three questions with numbers instead of
impressions:

- **How fast does memory answer?** — latency, which is what most interactive
  and single-threaded work is actually waiting on.
- **How much can be pushed through it?** — bandwidth, which is what many
  threads working at once run into.
- **Is there enough of it?** — the working set the machine can hold before the
  kernel starts evicting pages and stalling.

These are **study tools**, not a runtime configuration. They produce evidence
for a decision — is this upgrade worth it, did that change help, is this
machine short of memory — and then get out of the way.

Nothing here is specific to one machine. Sizes are derived at runtime where
that matters, comparisons are made against a baseline measured on **your**
hardware, and the tools degrade gracefully when something is unavailable.

---

## Setup

**Requirements**

| | |
|---|---|
| a C compiler | the benchmarks are built on first use, into the state directory |
| OpenMP | for the bandwidth test only; the rest runs without it |
| `root` | for the module sections only; skipped with a note otherwise |
| `dmidecode` | what the modules trained to |
| a driver on the SPD chips | `ee1004` for DDR4 — for what the modules ask for |

Nothing is installed system-wide, and nothing is written outside the state
directory. Deleting that directory removes every trace.

```
./memrun.sh baseline           # latency + bandwidth
./memrun.sh baseline --cap     # ... and the capacity sweep
```

The first run compiles what it needs; later runs rebuild only what changed.

---

## The measurements

### Latency — `lat`

Chases a pointer around a randomised cycle of cache lines, through buffers of
growing size, so the reported curve crosses each cache level and ends in main
memory. Each access depends on the one before it, so the processor cannot
overlap them and the number is real latency.

The last points of the curve are the ones worth quoting. The earlier ones are
useful mostly as a sanity check that the machine is behaving.

### Bandwidth — `bw`

STREAM-style copy, triad and read, swept across thread counts from one to the
number of processors. Sweeping matters: a single thread cannot keep enough
requests in flight to saturate a modern memory controller and will understate
the ceiling badly, while very high thread counts contend and can read below the
peak. The interesting figure is the shape of that curve, not one number from
it.

Array size defaults to well past last-level cache, computed at runtime.

### Capacity — `cap`

The one that maps onto how a machine actually feels. It fills a working set of
a given size, then reads it at random, and reports the fill rate, how many
pages the kernel had to evict, and how long the machine was **fully stalled**
on memory. Below the limit the fill rate is flat and nothing is evicted. Above
it, the fill rate collapses, eviction jumps and stall time appears.

Latency and bandwidth cannot answer "do I need more memory". This can: the size
at which that cliff appears is the honest capacity of the machine as configured
and loaded right now.

### Modules — `spd.py`

Prints every module's SPD side by side and says whether they agree.

This matters when modules from different kits or production runs share a
machine. The controller has to serve all of them, so it falls back to the
loosest value any one of them asks for — which can quietly slow down the
modules that were already there, with nothing in the booted system reporting
it. If the table shows no disagreement, that is not happening.

Three different questions, easy to conflate:

| question | where the answer is |
|---|---|
| what each module *asks for* | SPD — `spd.py` |
| what frequency and voltage were *trained* | `dmidecode` — in every run's header |
| what timings were actually *applied* | firmware setup only; no Linux interface exposes them on most platforms |

So if latency changes after adding modules while the SPD table shows agreement,
the cause is the extra electrical load of more modules per channel — not one
module holding the others back.

---

## Before and after

Run the same command on both sides of a change and compare the files:

```
./memrun.sh before-change --cap
# ... make the change ...
./memrun.sh after-change --cap
```

Every run records the conditions it was made under, because a comparison is
only valid against a run that matches. **Decide what would count as a
regression before measuring**, so the verdict is not written after seeing the
numbers.

---

## Pitfalls

Each of these was a wrong answer first.

**A benchmark you have not characterised proves nothing.** Reporting the mean
of a few passes gave a run-to-run spread near ten percent on a test system —
useless for detecting the few percent a memory change is typically worth. The
fix is to measure each size several times and report the *minimum*: noise on a
running machine only ever adds time. That brought the spread under one percent
and made a three percent difference meaningful.

**Some points on the latency curve never settle.** Buffers that straddle a
cache boundary stay noisy no matter how many passes they get, because the
result depends on how the allocator happened to colour the pages. The spread
column exists to expose them. Discard those sizes; do not average them away.

**The power profile moves these numbers more than the hardware does.** A
profile that disables boost or pins the clock changes memory latency by ten
percent and single-threaded bandwidth by far more — enough to swamp any
hardware change being investigated. Compare only runs made under the same
profile, on the same pinned core. Every run's header records both.

Worth knowing while reading that header: a power profile can disable core
boost entirely, and the global `cpufreq/boost` node may still read `1` while
every per-policy `cpuN/cpufreq/boost` reads `0`. The reliable tells are the
per-policy nodes and `scaling_max_freq` sitting at the base clock.

**A bandwidth test whose arrays fit in cache reports a figure the memory could
never deliver** — several times the real one, with nothing to signal it is
wrong. `memrun.sh` sizes the arrays from the detected last-level cache for this
reason. Override `MT_BW_MIB` only upward.

**Compressed swap makes a memory shortage invisible.** `zram` and `zswap`
absorb the zero-filled or repetitive pages a naive capacity test produces
almost for free, so the machine looks like it has several times the memory it
has. `cap` fills its buffer with incompressible data to defeat that.

**The trap that ended a run: compressed swap is not headroom.** An early
version of `cap` counted free swap as space it could use. Where swap is
compressed and RAM-backed, a page pushed into it frees almost nothing — least
of all one made incompressible on purpose. Counting it let the test allocate
far past what the machine could hold, and the run ended with the OOM killer.
The guard now considers only `MemAvailable`. On a machine with ordinary
disk-backed swap that is merely conservative, which is the right way to be
wrong. The sweep also stops climbing once eviction passes a threshold, rather
than pushing on to find the exact breaking point.

---

## What these numbers are not

Synthetic microbenchmarks rank configurations. They do not predict frame rates,
build times or how an application will feel. A latency figure and a triad score
are inputs to a decision, not the decision.

The capacity sweep is the exception worth trusting directly: stall time and
eviction counts are the same mechanism a user experiences as the machine
locking up for a second, and they are measured, not modelled.

Results depend on what else the machine is doing. A run made with a browser and
an editor open describes that machine honestly, but it is only comparable to
another run made under similar load. `MemAvailable` at the start of each
capacity step is recorded so this can be checked afterwards.

---

## Files

| | |
|---|---|
| `memrun.sh` | the entry point: records conditions, runs everything, saves one labelled result |
| `lat.c` | latency by pointer chasing, minimum of repeated passes |
| `bw.c` | STREAM-style bandwidth at one thread count |
| `cap.c` | working set against eviction and stall |
| `spd.py` | every module's SPD, side by side, with a verdict |

Results and built binaries go to `~/.local/state/mem-tune/` (override with
`MT_STATE`), never into the repository — they describe one machine at one
moment.

**Environment:** `MT_STATE` moves the output tree · `MT_CPU` picks the core the
latency test is pinned to · `MT_BW_MIB` overrides the bandwidth working set ·
`MT_CAP_SIZES` sets the capacity ladder — absolute on purpose, so a run before
a capacity change and one after it use the same steps · `MT_REPS` and
`MT_ITERS` trade latency accuracy for time.
