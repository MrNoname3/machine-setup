# graphics — GPU fixes and tuning

Unrelated parts, split by host:

- **Mint laptop** — NVIDIA GT 520M + Intel HD 3000 Optimus: suppress a phantom
  VGA output. With `mesa_kisak_ppa` Mesa comes from the kisak-mesa "fresh"
  PPA (signing key in `files/kisak-mesa.asc`, fingerprint
  `EB8B81E14DA65431D7504EA8F63F0F2B90935439`).
- **Mint with an NVIDIA card on nouveau** — with `nouveau_patched`, nouveau
  rebuilt through DKMS with the patches in `files/nouveau-patched`; see
  [nouveau cards](#nouveau-cards).
- **Mint desktop with an NVIDIA card** — the proprietary driver
  (`graphics_nvidia_branch`) and, with `graphics_nvidia_vaapi`, hardware video
  decoding for Chromium browsers; see [VA-API on the proprietary
  driver](#va-api-on-the-proprietary-driver). The primary user's open-file
  limit is raised, because the driver leaks a descriptor in the compositor for
  every frame and Cinnamon on Wayland would otherwise crash within minutes; an
  hourly check (`compositor-fd-watch`) asks for a re-login before it runs out.
- **Bazzite desktop** — Radeon RX 9070 XT (Navi 48, RDNA4): undervolt and power
  profiles. Everything after that section is about that part.

## nouveau cards

The patches in `files/nouveau-patched` each change only the GPUs they name, so
a card can move to any host with `nouveau_patched: true` and get what it needs
there. `nouveau_pstate` picks the level nouveau sets at load and after each
runtime resume, by the card's own pstate ids below; a card without that pstate
stays at its boot clocks. `nouveau_copy_engines: false` leaves buffer moves to
the graphics engine's M2MF.

| Card | GPU (PCI id) | Patches | pstates, core/memory MHz | Notes |
|---|---|---|---|---|
| GeForce GT 520M | GF108 (`10de:0df7`) | 0001–0010: reclocking from the VBIOS | `03` 50/135, `07` 202/324, `0f` 672/800 | [tools/mmiotrace-live/gf108](../../tools/mmiotrace-live/gf108) |
| GeForce GT 210 | GT218 (`10de:0a65`) | 0011: push buffer reads, without which Mesa 22.3+ hangs the GPU; 0012: the copy engine's channel; 0013: moving a buffer in use | `03` 135/135, `07` 405/324, `0f` 589/500 | [tools/mmiotrace-live/tesla](../../tools/mmiotrace-live/tesla) |
| GeForce 9800 GT | G92 (`10de:0614`) | 0011–0013 as above; 0014: the video clock, without which H.264 decoding hangs; 0015: the H.264 engine enabled; 0016: the memory PLL bit without which VRAM loses its contents on reclock; 0017: reclocking allowed | `0f` 600/900 | [tools/mmiotrace-live/tesla](../../tools/mmiotrace-live/tesla#geforce-9800-gt) |

A Tesla card (GeForce 8 to 300) needs more than the kernel module on Mint 22,
and a host gets all of it by joining the `nouveau_tesla` group in
`inventory.ini` ([group_vars/nouveau_tesla.yml](../../group_vars/nouveau_tesla.yml)):

- `nouveau_patched` at pstate `0f`;
- `nouveau_video_firmware`: the video engines' firmware, extracted on the host
  from NVIDIA's 340.108 driver, which may not be redistributed;
- kisak's Mesa rebuilt with the `mesa-*` patches of
  [tools/patched-deb](../../tools/patched-deb/) (VA-API surfaces a browser can
  take, decoders set up and torn down safely, nv50 clears of video surfaces,
  Wayland EGL that finds the GPU under a compositor without wl_drm), and
  Xwayland rebuilt to find the GPU as well; the Mesa build keeps the archive's
  version, so Steam's i386 Mesa stays installable;
- Brave's flags for VA-API on nouveau and the enhanced-h264ify extension, as the
  cards decode H.264 but not VP9 or AV1, and Celluloid's mpv options;
- the proprietary NVIDIA driver removed, as its packages blacklist nouveau.

A card on the proprietary driver has its group as well,
[group_vars/nvidia_580.yml](../../group_vars/nvidia_580.yml), so a card that
moves between hosts takes the host from one group to the other.

Brave then decodes H.264 in hardware, and Celluloid does through VA-API with
copy-back. VP9 and AV1 stay in software, as the engines cannot decode them.

## VA-API on the proprietary driver

Chromium-based browsers decode video in hardware only through VA-API, which the
proprietary driver does not provide. `nvidia-vaapi-driver` implements it on top
of NVDEC; its direct backend works with Chromium from version
`graphics_nvidia_vaapi_version` on. Ubuntu 24.04 ships an older version, so
until the Ubuntu base's archive catches up the role installs it from an
unofficial PPA (`graphics_nvidia_vaapi_ppa`, Launchpad's `ubuntuhandbook1/nvidia-vaapi`),
whose later releases arrive with the system's regular updates.

- **When the archive catches up**, the role installs the archive's package,
  removes the PPA and reports a change on every run until the PPA's tasks are
  deleted from the role.
- **NVIDIA driver updates** can break the direct backend, which uses the kernel
  module's internal interface. The role checks with `vainfo` on every run and
  fails when VA-API no longer goes through `nvidia-vaapi-driver`.

The browser needs flags as well (`brave_flags_extra` in the card's group), and ANGLE
has to run on EGL (`--use-angle=gl-egl`): on GLX the decoded frames never reach
the page. The card cannot decode AV1, so YouTube is steered to H.264 with the
enhanced-h264ify extension.

---

## What this does

The card is a factory-overclocked RX 9070 XT (ASUS, subsystem `1043:061a`,
16 GB Hynix, stock board power 317 W against a 304 W reference). At full load it
sits *exactly* on its power limit — 315.3 W measured against a 317 W cap — which
means it is power-bound, not voltage-bound. Lower the voltage and the firmware
spends the freed budget on clocks.

A `-100 mV` GFX voltage offset is worth **+9.5%** on this chip. That headroom can
be taken as speed, or traded back for less power and heat by lowering the cap.
The role ships the whole exchange rate as named profiles and applies one at boot.

## Enabling OverDrive

The voltage offset does not exist as a control until `PP_OVERDRIVE_MASK` is set
in amdgpu's feature mask, which needs a kernel argument and a reboot. Without it
`pp_od_clk_voltage` is absent and only the power cap works.

```
amdgpu.ppfeaturemask=0xfff7ffff
```

Nearly every guide says `0xffffffff`. **Do not use it.** The driver's stock value
here is `0xfff7bfff`, which is `0xffffffff` minus two bits: `PP_OVERDRIVE_MASK`
(`0x4000`) and `PP_GFX_DCS_MASK` (`0x80000`). Only the first is wanted;
`0xfff7ffff` adds exactly that one and leaves `GFX_DCS` disabled the way AMD
ships it. The role sets this with `rpm-ostree kargs --append-if-missing`.

## Choosing a profile

Seven profiles ship on this machine; what each one is worth is in the power-cap
table under [The measurements](#power-cap-all-at-100-mv).

```
amdgpu-tune --list           # profiles and their settings
amdgpu-tune --status         # what the GPU is actually doing right now
sudo amdgpu-tune performance # switch immediately
```

`systemctl start amdgpu-tune@performance` does the same thing. Either way the
change lasts until reboot, when the profile Ansible enabled comes back. To move
the default permanently, change `amdgpu_active_profile` in host_vars and re-run
the role:

```
./scripts/apply.sh desktop-bazzite --tags graphics -K
```

Profiles are data (`/etc/amdgpu-tune/profiles.conf`, generated from
`amdgpu_profiles`), so adding one is a host_vars edit, not a code change.

## The measurements

Produced with [`tools/gpu-tune/`](../../tools/gpu-tune/README.md), which
documents the full procedure and can reproduce all of it on any amdgpu card. The
short version:

```
./od-discover.sh                        # what the driver actually exposes
./bench.sh baseline-stock 4             # reference + measurement noise
SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A ./amdgpu-tuned.sh &
./sweep.sh 20 -200 2                    # undervolt sweep
./validate.sh -100 4 300000             # long-form validation
./capsweep.sh -100 300 280 260 240 221  # the speed/heat exchange rate
```

Benchmark: FurMark 2 Vulkan (`furmark-vk`), 1920x1080, no vsync, 60 s runs, each
preceded by a cooldown to 50 °C junction so no run starts on a hotter card than
the one it is compared against. First run of every set discarded as warm-up.

Repeatability was established before anything was tuned: **0.11% standard
deviation, 0.24% range** over three runs. That is what makes a 2% difference
meaningful and a 0.3% difference noise.

Re-measure before copying any of this to another card: the stable undervolt is a
property of the individual chip, and the useful cap depends on where that chip's
frequency curve flattens.

### Voltage offset

| offset | score | vs stock | core clock | measured vddgfx |
|-------:|------:|---------:|-----------:|----------------:|
|   0 mV | 22080 |        — |  2338 MHz | 801 mV |
| −20 mV | 22595 |   +2.33% |  2410 MHz | 797 mV |
| −60 mV | 23524 |   +6.54% |  2509 MHz | 780 mV |
| −100 mV | 24208 |  **+9.64%** | 2591 MHz | **767 mV** |
| −140 mV | 24281 |   +9.97% |  2602 MHz | 766 mV |
| −160 mV | 24274 |   +9.94% |  2602 MHz | 766 mV |
| −180 mV |     — | **GPU hang** | — | — |

`-180 mV` produced `ring gfx_0.0.0 timeout` followed by a successful GPU reset —
the machine recovered on its own.

**The measured voltage does not drop by the offset.** −160 mV of offset moves the
actual voltage by 35 mV. The offset shifts the *V/f curve*, not the operating
point: the card is power-bound, so it spends the freed budget on clocks, and the
higher clock claims most of the voltage back. Note that the power column of every
one of these runs sits at the 317 W cap. At −100 mV the card runs 2591 MHz at
767 mV — a point that would need ~867 mV on the stock curve, and a clock it could
therefore never reach within 317 W. What lowers voltage is the cap, not the
offset: at −100 mV throughout, 767 mV at a 317 W cap, 750 mV at 280 W, 728 mV at
221 W. `efficient`'s 750 mV comes from its cap, not from its undervolt.

**Why −100 mV and not −160.** The clock stops responding at about −100: steps
before it gain 40–52 MHz each, the two after gain 7 MHz and 4 MHz. The card is no
longer voltage-limited there, it has hit a frequency ceiling, so a deeper
undervolt buys nothing but a smaller margin to the hang at −180. −100 mV captures
97% of the available gain with twice the safety margin of −140. The generic "last
stable minus one step" rule would have picked −140; the shape of the curve says
otherwise, and the curve wins.

Validated at −100 mV over 4 × 5 minutes of continuous load: clean kernel log, no
artifacts, 0.03% score spread, 367.0 → 401.7 fps.

### Power cap (all at −100 mV)

This is also the profile list — each row is a shipped profile, all at −100 mV:

| profile | cap | fps | vs stock | junction | VRAM | fan |
|---------|----:|----:|---------:|---------:|-----:|----:|
| `performance` | 317 W | 401.7 | +9.5% | 87 °C | 90 °C | 2530 rpm |
| `balanced` | 300 W | 390.0 | +6.3% | 84 °C | 90 °C | 2175 rpm |
| **`efficient`** | **280 W** | 371.0 | **+1.1%** | 82 °C | 88 °C | 1870 rpm |
| `quiet` | 260 W | 349.0 | −4.9% | 80 °C | 88 °C | 1590 rpm |
| `eco` | 240 W | 328.0 | −10.6% | 79 °C | 88 °C | 1358 rpm |
| `minimal` | 221 W | 313.0 | −14.7% | 78 °C | 86 °C | 1208 rpm |

`efficient` is the default. There is a seventh, `stock` (0 mV, 317 W), which is
not a tuning setting but an off switch — useful for ruling the GPU out when
diagnosing something unrelated.

280 W is the break-even point: stock performance for 37 W less, 5 °C cooler and
660 rpm quieter. Efficiency improves monotonically downwards (1.27 → 1.41 fps/W),
which is another way of saying the card ships tuned to the wasteful end of its
own curve.

### Fan — a measured dead end

VRAM sat at 88–90 °C throughout the power sweep, barely moving across a 95 W
range, so the memory looked airflow-bound. It is not. Raising
`acoustic_target_rpm_threshold` from 1000 to 2200 (1929 → 2480 rpm actual)
changed VRAM temperature by **zero degrees** at every step. Junction drops 83 →
81 °C on the first step and then stops. Lowering `fan_target_temperature` from
76 to 70 did nothing either.

The limit is the thermal path from the memory dies to the heatsink, not the
volume of air, and no software setting reaches it. 88 °C is comfortably inside
GDDR6 spec, so this is a closed question rather than an open problem. **The stock
fan curve is left alone**, and no profile sets fan values.

## The trap that cost a whole measurement round
<!-- Kept here as well as in tools/gpu-tune: this one dictates the order of
     writes in amdgpu-tune, so it belongs next to the code it constrains. -->


Writing the reset/commit pair (`r` then `c`) to anything under
`gpu_od/fan_ctrl/` **silently drops an already-applied voltage offset** — while
`pp_od_clk_voltage` keeps *reporting* the offset as though it were still in
effect. The first fan sweep interleaved fan resets with measurements and
produced 348 fps readings that looked like a real effect; the card was actually
running at 776 mV instead of 749 mV with the undervolt quietly gone.

Two consequences, both baked into `amdgpu-tune`:

1. **Order matters.** Fan settings must be applied *before* the voltage offset,
   never after. The script applies the cap first and the offset last for this
   reason, even though no profile currently touches the fan.
2. **The reported offset is not evidence.** The only trustworthy check is the
   *measured* core voltage under load (`hwmon/in0_input`): ~801 mV at stock,
   750–765 mV at −100 mV. `amdgpu-tune --status` prints it, with the caveat that
   it only means anything while the GPU is busy.

## What is not achievable here

**Idle power and idle VRAM temperature.** Idle draw is ~28 W and the memory sits
at 62 °C with the fans stopped, and neither responds to any of this. The GFX
domain is mostly powered off at idle (GFXOFF), so there is nothing to undervolt,
and the memory clock never leaves its 456 MHz idle state — 734 samples at both
60 Hz and 75 Hz confirmed the display mode is not what pins it. Tuning does not
touch idle behaviour on this card; do not re-investigate.

## Reverting

Everything except the kernel argument is volatile — a reboot with the units
disabled returns the card to stock.

```
sudo amdgpu-tune stock                      # immediately, current session
sudo systemctl disable --now amdgpu-tune@efficient amdgpu-tune-resume
sudo rpm-ostree kargs --delete-if-present=amdgpu.ppfeaturemask=0xfff7ffff
```

Set `amdgpu_enable_overdrive: false` to keep the profiles on the machine without
the kernel argument, or drop `graphics` from `roles_enabled` to stop managing the
GPU entirely.

## Running the role

The Bazzite half writes `/usr/local/bin` and `/etc/systemd/system`, so it needs
root and cannot use the `-e ansible_become=false` invocation the other Bazzite
roles use:

```
./scripts/apply.sh desktop-bazzite --tags graphics -K
```
