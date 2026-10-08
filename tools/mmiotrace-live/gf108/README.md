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

Against nouveau as in Ubuntu's 5.15 kernel (`drivers/gpu/drm/nouveau`, applied
with `patch -p1` inside it). Both act on that one board only; every other
GF100-family GPU keeps reclocking disabled, as upstream has it.

- [0001](0001-clk-gf100-reclock-the-gf108-in-the-aspire-5750g.patch) enables
  reclocking and programs the clock block to the 390 driver's state for each
  level. Going up, core clocks and voltage change before memory, as the 390
  driver orders it.
- [0002](0002-fb-gf100-ddr3-scripts-for-the-gf108-in-the-aspire-5750g.patch)
  changes memory clocks by running the 390 driver's DDR3 scripts through
  nouveau's PMU script engine (memx).

Built as an out-of-tree module against the running kernel's headers:

```
make -C /lib/modules/$(uname -r)/build M=$PWD NOUVEAU_PATH= modules
```

`NOUVEAU_PATH=` empties the prefix nouveau's Kbuild puts before its include
paths, which only fits an in-tree build. A pstate is then chosen through
debugfs, for example `echo 0f > /sys/kernel/debug/dri/1/pstate`; nouveau does
not change levels by itself.

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

nouveau's own `gf100_ram_calc` was written the same way, from a trace of a
GDDR5 board, and carries the same opcodes as comments.

## Next

- The installed system: the same patches on its kernel's nouveau, as a DKMS
  module, and a level chosen at boot and after the GPU resumes from runtime
  power-off.
- What decides each recorded value, so the VBIOS can produce them for other
  boards and the patches can go upstream.
