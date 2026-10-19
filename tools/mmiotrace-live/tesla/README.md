# Tesla cards (GeForce 8 to 300) on nouveau

What a Tesla card needs to run on nouveau at full speed, measured on the 340
[live image](../README.md) in a Phenom desktop (legacy BIOS, nForce chipset).
The graphics role builds the patch below into its `nouveau-patched` module;
[roles/graphics/README.md](../../../roles/graphics/README.md#nouveau-cards)
lists the cards by PCI id.

## GeForce GT 210

GT218 (`10de:0a65`, subsystem `10b0:1401`), 1 GiB DDR3. The VBIOS's levels, as
core/shader/memory MHz:

| nouveau pstate | Clocks |
|---|---|
| `03` | 135 / 270 / 135 |
| `07` | 405 / 810 / 324 |
| `0f` | 589 / 1402 / 500, the card's stock clocks |
| boot | 405 / 810 / 405 |

nouveau reclocks the GT218 as it is upstream, and `0f` is the one to set.
With five `glmark2-drm` scenes off-screen at 800×600, the score goes from 332
at the boot clocks to 453 at `0f`; a [VRAM test](../vramtest.c) across nine
level changes finds no flipped bit.

## GeForce 9800 GT

G92 (`10de:0614`, subsystem `1043:8314`), 512 MiB GDDR3. The VBIOS has one
level, `0f` at 600 / 1500 / 900 MHz core/shader/memory, and the card boots at
400 / 810 / 400. Upstream nouveau does not reclock G92 (`g84_clk_new` allows
it from G94 on); with the two patches under [Reclocking](#reclocking) it sets
`0f`.

### The video clock

G92's PVP2 and PBSP engines run on the video clock, which the VBIOS leaves on
nvclk divided by two (`0xc040` bits 10-11 = 3, divider `0x4800` bits 8-10 =
1). At the boot clocks PVP2 decodes 720p MPEG-2 at about 10 frames a second,
and PBSP hangs on its first H.264 command, its engine registers faulting
from then on; nouveau has kept PBSP off on G92 since commit 194d68dd051c for
that reason. NVIDIA's 340 driver, traced with mmiotrace while it loads,
moves the video clock to XPLL before using the engines:

| Step | Write |
|---|---|
| video clock to the crystal, bit 9 set | `0xc040` bits 8-11 = `0x2` |
| XPLL post divider and video divider to 0 | `0x4030` bits 16-21 = 0, `0x4800` bits 8-10 = 0 |
| XPLL coefficients | `0x4034` = N `0x12`, M `0x02` |
| XPLL fed from the PCIE reference | `0xc040` bit 25 |
| XPLL P = 1, video divider 1 | `0x4030` bits 16-21 = `0x09`, `0x4800` bits 8-10 = 1 |
| video clock to XPLL, bit 8 set | `0xc040` bits 8-11 = `0xb` |

The same writes with nouveau and the NVIDIA driver never loaded bring MPEG-2
to about 60 frames a second and H.264 decoding through PBSP without a hang.
Only the PLL and video-clock writes matter: moving the video clock to XPLL
without bit 25 and the coefficients stops PVP2 as well. `0014` in the
graphics role (`0004` in [upstream/](upstream/)) makes these writes at
devinit on G92, with N and M from the VBIOS's XPLL limits for 450 MHz, which
gives the driver's values; `0015` (`0005`) turns PBSP back on.

### Reclocking

nouveau's GDDR3 reclock computes the same timings for G92 as its VBIOS sets,
but clears bit 14 of the MPLL control, `0x004008`, for the switch and leaves it
clear, as the rammap entry's `rammap_00_16_40` is zero. With that bit clear
VRAM loses its contents: the BAR page tables read back as not present right
after the switch, and the screen fills with stripes. NVIDIA's driver switches
the memory clock with a short HWSQ script, which
[hwsq-dis.py](hwsq-dis.py) reads out of the trace: precharge, self-refresh,
the new MPLL coefficients, out of self-refresh and a DLL reset, with bit 14
never cleared. `0016` (`0006`) keeps the bit on G92, and `0017` (`0007`)
allows reclocking there. At `0f` the [VRAM test](../vramtest.c) finds no
flipped bit, also with more textures than VRAM holds, and the five
`glmark2-drm` scenes off-screen at 800×600 score 2314.

## Push buffer reads

With Linux 6.2 or later and Mesa 22.3 or later, a GT218 soon fails under
load: the kernel logs `DMA_PUSHER` `INVALID_CMD` errors, then `CACHE_ERROR`,
`ILLEGAL_MTHD` and `DATA_ERROR` from PGRAPH, and in the end PGRAPH hangs and
only a reboot brings the GPU back. Clocks do not matter; it happens at the
boot clocks too.

`nv50_vmm_flush` invalidates the TLB of each engine that has an object in the
VMM, and BAR's, but never PFIFO's (VM engine 5 in envytools' `G80_VM_ENGINE`),
although the DMA pusher reads the IB ring and the push buffers through the
channel's VMM. After a remap the pusher may read the old pages. Until commit
4a16dd9d18a0 ("drm/nouveau/kms: switch to drm fbdev helpers", Linux 6.2) the
accelerated fbcon drew through the kernel's channel, in another VMM, and the
channel switches that caused hid the missing invalidate. The commit came out
of a kernel bisect between 6.1 and 6.2 with Mesa 22.3.6, and these runs on
its parent and on the commit itself narrowed it down:

| Kernel | Result |
|---|---|
| parent | clean |
| parent, `nouveau.nofbaccel=1` | fails |
| parent, fbcon cursor not blinking and console log level 1 | fails |
| 4a16dd9d18a0 with a 2D object bound on the kernel's channel | fails |
| 4a16dd9d18a0 with PFIFO's TLB invalidated on every VMM flush | clean, also through the whole default `glmark2` run |

The patch, `0001` in [upstream/](upstream/) and `0011` in the graphics role,
takes a reference on FIFO in a channel's VMM while the channel is in it, and
invalidates PFIFO's TLB while one is held.

## Copy engine channel

Since commit 04e0481526e3 ("nouveau/dmem: Fix privileged error in copy engine
channel", Linux 6.12) nouveau asks for a privileged channel for the copy
engine on every GPU, but only the FIFOs from Kepler on have privileged
channels. On a GT218, as on every Tesla and Fermi GPU with a copy engine, it
logs `failed to create ce channel, -22` and moves buffers through its main
channel. `0002` in [upstream/](upstream/), `0012` in the graphics role, asks
for a privileged channel only from Kepler on.

## Moving a buffer in use

`nouveau_bo_move` pointed a buffer's VMAs at its new placement first, waited
for the GPU to finish with the buffer second, and copied the contents third.
A channel still using the buffer read the new placement before the copy had
filled it. Since Mesa 22.3 every GL context has a channel of its own, and a
browser's GPU process submits from several, so one context's submission can
move a buffer another one is still reading, which gives push buffer and
PGRAPH errors like the ones above. The stale PFIFO TLB used to hide this as
well, by reading the old placement. `0003` in
[upstream/](upstream/), `0013` in the graphics role, waits for the buffer
before remapping it.

## Video decoding

The GT218's VP4 engine decodes H.264, MPEG-2 and VC-1 with firmware that only
NVIDIA's driver carries: envytools' `extract_firmware.py` takes it out of the
340.108 driver into `/lib/firmware/nouveau/`, and it may not be
redistributed. VA-API players then decode in hardware, 720p H.264 at about
110 frames a second. Chromium and Firefox take decoded frames as exported
dma-bufs, and Mesa refused to export the interlaced surfaces nouveau's video
engines decode into; with the Mesa patches of
[tools/patched-deb](../../patched-deb/) it exports a progressive copy, and Brave
plays 1080p H.264 at about a quarter of the CPU software decoding takes. VLC 3
maps decoded surfaces with vaDeriveImage, which needs both planes in one
buffer, and nouveau keeps them apart, so VLC stays in software; Celluloid
(mpv) decodes in hardware with copy-back.

The 9800 GT's VP2 engines (PBSP for H.264, PVP2) use the `nv84_*` files the
same extraction gives. Mesa's VP2 decoder zeroed its rings with a clear of a
render target it made up around each ring, which the template surfaces of
Mesa 25.2 broke, and it tore itself down while the engines could still be
running; the `mesa-nv84-*` patches fix both. A browser's GPU process also
needs `mesa-winsys-object-del.patch`: Mesa deleted its nouveau objects
through the wrong file descriptor, the kernel kept them, and the VP2
decoder's probe for PBSP failed when it reused a freed object's address.

With all of these, Brave decodes H.264 on the 9800 GT with about a fifth of
a core, 720p30 without a dropped frame; at 1080p it keeps up with about 23
frames a second of a 6 Mbit/s stream, as does Celluloid.

## Upstream

All seven patches apply to nouveau as in kernel 7.0, `0004` to `0007` to
mainline as well. Together with the rest of the graphics role's set, on Linux
7.0 at `0f`, the GT218 runs the whole default `glmark2` set with Ubuntu's Mesa
25.2, and the five scenes above with kisak's 26.2, without a GPU error; the
9800 GT decodes H.264 and MPEG-2 through VA-API, and survives decodes cut
short, without one.
`checkpatch.pl --strict` finds the sign-off missing, the one-line `case` style
of the switch `0001` adds to and the names nouveau already uses; the author
line is a placeholder, as in the
[GF108 series](../gf108/README.md#upstream-series).
