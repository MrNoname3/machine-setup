# GF108 (GeForce GT 520M) clock changes

What the NVIDIA 390 driver does to move a GF108 between its performance levels,
recorded with [trace-clocks.sh](../trace-clocks.sh), and two nouveau patches
that do the same for the GF108 in the Acer Aspire 5750G (PCI subsystem
`1025:0505`, 1 GiB DDR3). The levels, from the VBIOS, as core/memory MHz:

| Level | 390 driver | nouveau pstate |
|---|---|---|
| 0 | 50 / 135 | `03` |
| 1 | 202 / 324 | `07` |
| 2 | 672 / 800 | `0f` |

## The patches

[0001](../../../roles/graphics/files/nouveau-gf108/0001-clk-gf100-reclock-the-gf108-in-the-aspire-5750g.patch)
and
[0002](../../../roles/graphics/files/nouveau-gf108/0002-fb-gf100-ddr3-scripts-for-the-gf108-in-the-aspire-5750g.patch),
applied with `patch -p1` inside `drivers/gpu/drm/nouveau`, are kept with the
graphics role that installs them; [5.15/](5.15/) has them for Ubuntu's 5.15
kernel, which the live system runs. Both act on that one board only; every
other GF100-family GPU keeps reclocking disabled, as upstream has it.

- 0001 enables reclocking and programs the clock block to the 390 driver's
  state for each level. Going up, core clocks and voltage change before memory,
  as the 390 driver orders it.
- 0002 changes memory clocks by running the 390 driver's DDR3 scripts through
  nouveau's PMU script engine (memx).

On the installed system the graphics role builds them through DKMS:
[prepare.sh](../../../roles/graphics/files/nouveau-gf108/prepare.sh) takes
nouveau from the Ubuntu source of the running kernel, checked along the
archive's signature chain. By hand, as an out-of-tree module against the
running kernel's headers:

```
make -C /lib/modules/$(uname -r)/build M=$PWD modules
```

On 5.15, nouveau's Kbuild prefixes its include paths for an in-tree build, and
`NOUVEAU_PATH=` on the make line empties that prefix. A pstate is then
chosen through debugfs, for example
`echo 0f > /sys/kernel/debug/dri/1/pstate`; nouveau does not change levels by
itself.

[pstate.sh](pstate.sh) shows the pstate table and switches levels without
letting a hang in the clock code take the shell with it.
With [bench.sh](bench.sh) (five `glmark2` scenes, PRIME offload), every
transition and chain of them fault-free:

| pstate | Core / memory | glmark2 |
|---|---|---|
| `03` | 50 / 135 MHz | 256 |
| `07` | 202 / 324 MHz | 738 |
| `0f`, memory left at 324 MHz | 670 / 324 MHz | 898 |
| `0f` | 670 / 800 MHz | 2037 |

At `0f`, the full `glmark2` suite passes and `glmark2 --validate` matches every
scene that has a reference image.

On the installed system (Mint 22, kernel 7.0, Mesa 25.2.8, built through the
graphics role) the same run scores 558 at the boot clocks and 1216 at `0f`;
nouveau sets `0f` at load and again whenever the GPU comes back from runtime
power-off, memory included. There, `glmark2 --validate` fails the same eight
shader scenes (conditionals, function, loop) at `0f`, at `07`, and with the
clocks the VBIOS leaves, so those failures belong to that Mesa, not to the
clocks.

## Core clocks

nouveau has code to change GF100-family clocks but creates the clock subdev
with reclocking disabled, so a pstate write returns `ENOSYS`. Enabled as it is,
`0f` leaves the GPU slower than `07` and it soon stops answering: the domains
nouveau programs from the VBIOS clocks differ from the 390 driver's
([clock-block-states.txt](clock-block-states.txt), the last value seen for each
register in each state):

- **0x1370e0** feeds domains 7, 8, 9 and 14. The 390 driver keeps it running;
  nouveau switches it off when domain 7 can run from a divider, then tries to
  move domain 8 onto it, and the source select never acknowledges.
- **Domain 8** runs from the fixed 100 MHz source at level 2
  (`0x137180 = 0x07000102`); nouveau runs it from SPPLL1 undivided.
- **The gpc PLL** takes its reference from SPPLL0/4 (`0x137120 = 0x1003`);
  nouveau leaves SPPLL1 selected.

0001 therefore programs the recorded register values instead of computing them.
[replay-blob-L2-core.nvreg](replay-blob-L2-core.nvreg) and
[replay-blob-L0-core.nvreg](replay-blob-L0-core.nvreg) do the same by hand with
[nvreg](../nvreg.c), under a loaded nouveau that is not reclocking.

## Memory clocks

The 390 driver does not write the memory controller from the CPU. It uploads a
script into the PMU's data memory (address port `0x10a1c0`, data port
`0x10a1c4`, buffer at `0x5800`) and the PMU runs it with DRAM in self-refresh.
[pmu-scripts.py](pmu-scripts.py) pulls the scripts out of a trace, as text or,
with `--c`, as C arrays; [pmu-scripts-390.txt](pmu-scripts-390.txt) holds every
one from a full cycle. Each command is a header `(nwords << 16) | opcode` and
its arguments, which 0002 turns into memx commands:

| Opcode | Arguments | Reading | memx |
|---|---|---|---|
| `21` | address/value pairs | register writes | `WR32` |
| `2e` | ns | delay | `DELAY` |
| `00`, `01`, `15` | value; address; mask, timeout | wait for `(reg & mask) == value` | `WAIT` |
| `20` | 1 or 0 | block, unblock the GPU's memory traffic | `ENTER`, `LEAVE` |
| `14` | head, timeout | wait for a display head | `VBLANK` |
| `3a` | count | follows writes to `0x13d834`; not identified | a delay |
| `34` | `0x0a`, `0x0b` | brackets the blocked part; not identified | dropped |
| `16` | – | end | – |

The scripts are identical each time they run, and DDR3-specific: mode register
writes through `0x10f300`/`0x10f320`, timings in `0x10f224` and
`0x10f290`–`0x10f2a0`, the memory PLL at `0x132000`/`0x132004`. Four of them
cover every change: from the VBIOS state (324 MHz, memory PLL off) to 800, and
800 → 324 → 135 → 800. Each memory state has one script leading out of it, so
any target is at most two scripts away; the memory PLL's coefficients tell the
states apart.

The patch's `gf108ddr3.h` is the output of

```
pmu-scripts.py --header gf108_ddr3 --mhz 793=800 clocks.mmio
```

where `--mhz` names the memory clock `nvidia-settings` reports (793) after the
VBIOS level it stands for.

nouveau's own `gf100_ram_calc` was written the same way, from a trace of a
GDDR5 board, and carries the same opcodes as comments.

## From trace to patch

The order that worked, each step on the live system with nothing to lose:

1. **Diff the states.** The last value of every register in the clock block
   at each level ([lastval.awk](lastval.awk)), from the proprietary driver and
   from nouveau, side by side ([clock-block-states.txt](clock-block-states.txt)).
2. **Replay before writing code.** Put the recorded state into the hardware by
   hand under a loaded nouveau ([nvreg](../nvreg.c) and the `.nvreg` scripts),
   then benchmark. That separated "nouveau computes the wrong values" from
   "these values or this order do not work here".
3. **Core first, memory second.** `nouveau.config=NvMemExec=0` makes nouveau
   build the memory script without running it, so a pstate change touches core
   clocks only.
4. **Measure, then check the picture.** `glmark2` scores show whether clocks
   took effect; `glmark2 --validate` (`bench.sh --validate`) shows whether
   rendering is still right.
   When a scene fails, repeat it in the state the VBIOS leaves (write `none` to
   the pstate file and let runtime power management switch the GPU off and on):
   failures that remain there are not the clocks' doing.
5. **Then the installed system**, through the graphics role.

A test nouveau loads beside the proprietary driver's packages with
`modprobe -C <empty file> nouveau`, since those packages alias nouveau off.

## A new kernel series

DKMS rebuilds the module only for kernels of the series its source came from,
and other kernels boot with their stock nouveau. Under a new series, run the
graphics role again: prepare.sh fetches that series' source and applies the
patches. If a hunk no longer applies, port it on a copy of the new nouveau,
build it against the new headers, and replace the patches in
`roles/graphics/files/nouveau-gf108`; from 5.15 to 7.0 only the clock
subdev's allocation call changed.

## Toward upstream

The patches carry values recorded on one board. Every Fermi chip, GF100 to
GF119, runs the same `gf100_clk` and `gf100_ram_calc` code, and the GT 520M
alone comes as GF108 (`0DED`, `0DF7`) and GF119 (`1050`, `1052`, and the
`1051` GT 520MX), with whatever DDR3 each laptop maker fitted. For all of them,
nouveau has to compute these values from the VBIOS. What the VBIOS of this
board (decoded with [nvbios.sh](../nvbios.sh)) already explains:

- **Clock sources.** Each domain's entry in the performance table carries
  flags beside its frequency: `0x4000` on the domains the 390 driver runs from
  a PLL at level 2 (shader, hub06, hub07, memory), `0x8000` ("force no PLL")
  on the ones it never does. `calc_clk` ignores both.
- **Memory timings.** The timing table (version 10) entries 4, 5 and 6 give the
  `0x10f290`, `0x10f298` and `0x10f2a0` values of the 135, 324 and 800 MHz
  scripts exactly; a few bits of `0x10f294` and `0x10f29c` come from somewhere
  else, likely the ramcfg entry.
- **Domain 8 at level 2.** The source select of a divider (`0x137160` and
  on) picks, with `SRC = 2`, one of several inputs in bits 24 to 26: 0 is the
  100 MHz reference, 1 a 277 MHz one, and 7 the output of PLL `0x137040`,
  which feeds domain 2 at level 2. That is how the 390 driver runs domain 8 at
  the 1344 MHz the VBIOS asks for while it "forces no PLL": it borrows domain
  2's. At its lower levels, domain 8 runs from SPPLL1 (1620 MHz) through
  dividers, at the VBIOS's 540 and 810 MHz. nouveau reads every `SRC = 2` as
  100 MHz.

Measured with the GPU's clock counters ([clocks.sh](clocks.sh)), which count
for 0x3fff periods of the 27 MHz crystal: the shader clock and domain 7 run at
what the VBIOS asks for at every level, and the SPPLL reference at 1620 MHz. The
counters are not in envytools' register database; the 390 driver's own use of
them in the trace showed how they work. Input 2 of the select, chosen at
level 1, stopped the domain and took the GPU off the bus until a reboot: an
input whose source is off has no clock.

- **The PLLs' reference dividers.** Each PLL's reference passes a divider of
  the same `(src × 2) / (div + 2)` form as the domains' own: SPPLL1 1620 MHz
  through `0x13715c = 0x81200606` gives 405 MHz, and PLL `0x1370e0` (37/14)
  makes 1070 MHz of it, which the counter confirms for domain 7. `read_div`
  skips that divider for domains above 2, and so reports 1620 × 37 / 14 =
  4281 MHz for domain 7.

Still open:

- When the shared PLL `0x1370e0` may be switched off.
- What inputs 2 to 6 of the select are.
- Opcodes `0x34` and `0x3a` of the memory scripts.
- A DDR3 path for `gf100_ram_calc` built from the VBIOS tables, after the DDR3
  code nouveau has for GT215 (mode registers through `sddr3`, the memory PLL
  from the VBIOS PLL limits), shaped like the recorded scripts.
- Traces from other GF108 and GF119 boards, which the live ISO and
  [trace-clocks.sh](../trace-clocks.sh) can take; only what is decoded from them
  may be shared.

nouveau's level choice stays manual: it has no governor that follows the load.
On this Optimus laptop the GPU is off whenever nothing renders on it, so a
fixed `0f` behaves much like the 390 driver under load.
