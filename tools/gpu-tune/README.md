# gpu-tune — measuring an AMD GPU undervolt

A set of scripts for finding a safe undervolt and power cap on an `amdgpu` card,
measuring what they are worth, and proving the result rather than assuming it.

These are **study tools**, not a runtime configuration. They produce the numbers;
the `graphics` role turns a chosen result into a permanent, reproducible setup.
See [`roles/graphics/README.md`](../../roles/graphics/README.md) for the
conclusions this set produced on the RX 9070 XT, and for how to make a result
stick across reboots.

Nothing here is card-specific. The device, the hwmon node and the driver's
accepted ranges are all resolved at runtime, and comparisons are made against a
baseline you measure on **your** card, not against a constant.

---

## Setup

**Requirements**

| | |
|---|---|
| An `amdgpu` GPU | the scripts find it themselves; set `GPU_PCI=0000:0a:00.0` to pick one on a multi-GPU machine |
| `flatpak` | for the benchmark |
| `ksshaskpass` (or any askpass) | so the one privileged step can prompt graphically |
| `journalctl` | kernel-fault detection reads the boot journal |

**Install the benchmark.** FurMark 2 is the workload: it is CLI-drivable, needs
no menu navigation, terminates on its own, reports a machine-readable score, and
has an artifact scanner that catches a marginal undervolt as visual corruption
before it becomes a hang.

```
flatpak install --user -y flathub com.geeks3d.furmark
```

User scope on purpose — this is a temporary study tool, not part of the machine's
managed app set.

> The flatpak's default command is `FurMark_GUI`, which **silently ignores every
> CLI flag**. The scripts run `--command=furmark` instead. If you invoke FurMark
> yourself, do the same, or you will get a 150-second run that never renders
> anything and telemetry that looks like idle.

**Enable OverDrive.** The voltage offset does not exist as a control until
`PP_OVERDRIVE_MASK` is set. Without it, `pp_od_clk_voltage` is absent and only
the power cap can be measured.

```
sudo rpm-ostree kargs --append-if-missing=amdgpu.ppfeaturemask=0xfff7ffff
sudo systemctl reboot
```

Use `0xfff7ffff`, not the `0xffffffff` from most guides: the stock value is
`0xfff7bfff`, and `0xffffffff` re-enables `PP_GFX_DCS_MASK` as well, which AMD
disables deliberately. On a non-ostree distro, add the same argument through your
bootloader instead.

---

## Safety

Worth understanding before running an unattended sweep that is *designed* to find
the point where the card fails.

**Everything is volatile.** Voltage offset, power cap and fan settings are sysfs
values. A reboot restores the card to stock on its own; `revert.sh` exists only
so you do not have to reboot. The kernel argument is the sole persistent change,
and it is inert — it exposes an interface, it does not set anything.

**Privileges are session-scoped.** `amdgpu-tuned.sh` runs as root, started once
with a graphical password prompt, and takes commands over a FIFO for the rest of
the session. It is not a root shell: fixed verb list, every number range-checked
against both a hard limit and the range the driver reports, and a **stock reset
on every exit path** — normal stop, signal, or crash. A **15-minute watchdog**
resets and exits if no command arrives, so a dead session or a hung machine
cannot leave a tuned value applied. It installs nothing; when the process exits,
the privilege is gone with it.

**Failures are usually recoverable.** In testing, the first failing offset
produced a `ring gfx timeout` and a GPU reset that the driver handled by itself.
A hard lockup is possible though, so do not leave unsaved work on the machine
during a sweep.

---

## The procedure

Each step depends on the one before it. Roughly 2–3 hours end to end, mostly
unattended.

### 1. Discovery — before anything else

```
./od-discover.sh
```

Confirms the kernel argument took effect and prints the ranges **the driver
itself advertises** plus the exact syntax `pp_od_clk_voltage` documents. Design
the sweep from this output; do not assume RDNA3 and RDNA4 behave alike (RDNA4
exposes `SCLK_OFFSET`, an offset, where earlier generations took absolute
clocks).

### 2. Baseline — establish the reference and the noise floor

```
./bench.sh baseline-stock 4
```

Four runs at stock, first discarded as warm-up. Two things come out of this:

- the reference every later comparison is made against (read automatically from
  the result file — nothing is hardcoded);
- **the measurement noise**, printed as a standard deviation. This is the number
  that decides what the study can conclude. If the spread is 3%, a 2% gain is not
  a finding. On the reference card it was 0.11%.

Do not skip this and do not reuse someone else's baseline.

### 3. Start the privileged helper — the only interactive step

```
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./amdgpu-tuned.sh &
```

One password prompt. Everything after this runs unattended.

### 4. Undervolt sweep

```
./sweep.sh 20 -200 2
```

Walks the offset down in 20 mV steps until instability, checking three
independent signals at every point: FurMark's artifact scanner, the kernel log,
and the benchmark result itself. Stops at the first hit and restores stock.

**Read the result; do not just take the last stable value.** The script prints
the per-step clock gain for a reason. If the clock stops climbing before the
failure point, every offset past that buys nothing and only shortens the margin
to the failure — pick the knee. On the reference card the last stable offset was
−160 mV, and the right answer was −100 mV: 97% of the gain with twice the margin.

### 5. Validate the choice

```
./validate.sh -100 4 300000
```

Four five-minute runs. The sweep proves a setting survives two 60-second runs,
which is enough to rank candidates and not enough to trust one. This watches the
kernel log across the whole window and reports the **measured** voltage — see
Pitfalls.

### 6. Power-cap sweep — the exchange rate

```
./capsweep.sh -100 300 280 260 240 221
```

The undervolt frees up power budget; this measures what it is worth if you spend
it on cooling instead of speed. The output names the lowest cap that still
matches the untuned baseline: at or above that line you get less power, lower
temperatures and less noise **for free**.

### 7. Fan — optional, and often a dead end

```
./fansweep.sh -100 280 1000 1400 1800 2200
```

Whether more airflow buys anything. On the reference card it bought nothing at
all: VRAM sat at 88 °C across the entire range. If your VRAM does not move
either, it is bound by the thermal path rather than airflow, and no software
setting reaches it.

### 8. Re-test anything that does not fit a trend

```
GT_AB_OFFSET=-100 ./ab-test.sh "fan-acoustic-target 1800" "fan-acoustic-target 1400" 4
```

A sweep walks its points in order, so anything drifting during the session gets
attributed to whichever setting happened to be measured at the time.
Interleaving separates cause from drift. This is how the one anomalous result in
the reference study turned out to be a measurement artifact rather than a
finding — worth the 20 minutes before a wrong number reaches a config file.

### 9. Finish

```
echo stop > /run/amdgpu-tune-session.fifo     # or: sudo ./revert.sh
```

Then make the result permanent through the `graphics` role rather than by hand.

---

## Pitfalls

**The reported offset is not evidence.** Writing the reset/commit pair to
anything under `gpu_od/fan_ctrl` **silently drops an applied voltage offset**,
while `pp_od_clk_voltage` keeps reporting it as still set. A whole measurement
round was lost to this: the card was running at 776 mV instead of 749 mV with
the undervolt gone, and the numbers looked like a real fan effect.

The only trustworthy check is the **measured** core voltage under load
(`hwmon/in0_input`, the `vddgfx` column). Every script here records it, and
`fansweep.sh` re-applies and re-verifies the offset at every point. If you add
fan settings to a tuning sequence, apply them **before** the voltage offset,
never after.

**Scores are not comparable across run lengths.** FurMark's score is
proportional to duration (60 s → ~24k, 300 s → ~120k). Compare fps between runs
of different lengths; the score only within one length.

**Cooldowns matter.** Every run waits for a fixed junction temperature first
(`GT_COOL_TO_C`, default 50 °C), so no run starts on a hotter card than the one
it is compared against. Without this, later points in a sweep are systematically
penalised. Note that VRAM cools more slowly than the junction, so memory
temperature still creeps up slightly across a long session.

**FurMark is not a game.** It is a deliberately extreme, unrealistically uniform
load — excellent for finding the stability floor and characterising the V/f
curve, and conservative in the right direction (stable here usually means stable
in games). It is not a substitute for validating a daily-driver setting in the
games you actually play.

---

## Scripts

| | |
|---|---|
| `common.sh` | shared helpers — device discovery, paths, fault detection. Sourced, not run |
| `od-discover.sh` | read-only: what this card exposes and what ranges it advertises |
| `sample.sh` | telemetry sampler → CSV. Read-only, works alongside any workload |
| `summary.sh` | load-only statistics from one or more sampler CSVs |
| `bench.sh` | the measurement primitive: N benchmark runs, cooldowns, spread |
| `amdgpu-tuned.sh` | the privileged session helper (root, FIFO, watchdog) |
| `sweep.sh` | undervolt sweep with three-way instability detection |
| `validate.sh` | long-form validation of one offset |
| `capsweep.sh` | power-cap sweep — the speed/heat exchange rate |
| `fansweep.sh` | fan sweep — noise vs temperature |
| `ab-test.sh` | interleaved A/B/A/B, for separating a real effect from drift |
| `revert.sh` | undo everything a session can leave behind |

Results and telemetry go to `~/.local/state/gpu-tune/` (override with
`GT_STATE`), never into the repo — they are machine- and session-specific data,
and a sweep produces hundreds of files.

**Environment:** `GPU_PCI` picks a card · `GT_STATE` moves the output tree ·
`GT_COOL_TO_C` / `GT_COOL_MAX_S` tune the cooldown · `GT_DEMO` selects the
FurMark demo (`furmark-vk` by default; `--demolist` shows the rest) ·
`GT_BASELINE_LABEL` points comparisons at a different reference run.
