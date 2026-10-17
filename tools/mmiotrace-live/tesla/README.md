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

The patch, [upstream/](upstream/) and `0011` in the graphics role, takes a
reference on FIFO in a channel's VMM while the channel is in it, and
invalidates PFIFO's TLB while one is held. It applies to nouveau as in kernel
7.0. `checkpatch.pl` finds the sign-off missing and the one-line `case` style
of the switch it adds to; the author line is a placeholder, as in the
[GF108 series](../gf108/README.md#upstream-series).
