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

The graphics role builds nouveau with the patches in
[roles/graphics/files/nouveau-gf108](../../../roles/graphics/files/nouveau-gf108),
applied with `patch -p1` inside `drivers/gpu/drm/nouveau` of kernel 7.0:

- 0001–0007, the [upstream series](#upstream-series), compute the core
  clocks and the DDR3 settings from the VBIOS;
- 0008, kept out of that series, enables reclocking on the GF108 (chipset
  `C1`) and, going up, changes core clocks and voltage before memory, as the
  390 driver orders it.

Every other GF100-family GPU keeps reclocking disabled, as upstream has it.
[5.15/](5.15/) holds the earlier, board-specific pair for Ubuntu's 5.15 kernel,
which the live system runs: they program the 390 driver's recorded clock
registers and replay its four DDR3 scripts, on the Aspire 5750G (subsystem
`1025:0505`) only.

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
| `3a` | count | follows a write to `0x13d834`; the count is the writes to `0x10f600`–`0x10f8ff` since the last one | a delay, 10 µs per write |
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

## DDR3 from the VBIOS

Upstream patch 0007 computes these scripts instead of replaying them.
[ddr3-model.py](ddr3-model.py) is the same sequence in Python: from the
register state the 390 driver left before each script, it reproduces the
800 → 324, 324 → 135 and 135 → 800 scripts word for word, `0x3a` counts
included, and the first one apart from the display stop, which the 390 driver
leaves out while no head is running. Where each value comes from:

| Registers | Source |
|---|---|
| `0x10f290`, `0x10f298`, `0x10f2a0` | timing entry: RP, RAS, RFC, RC; WR, WTR; RRD |
| `0x10f294` | timing entry: RCDWR, RCDRD, CWL, CL; CL one lower while the DLL is off |
| `0x10f29c`, `0x10f224` | timing entry bytes 0x14, 0x15, 0x0d; byte 0x12 |
| `0x10f300`/`304`/`320` | `nvkm_sddr3_calc` (MR0–MR2), DLL off from the ramcfg entry |
| `0x10f658`, `0x10f660` | ramcfg bytes 5–8, as GT215's `0x1005a0`/`0x1005a4`, while rammap bit `04_08` is set; else `0x10f910`/`914` get `0x2000` |
| `0x10f610`, `0x10f614`, `0x10f200` bit 12 | ramcfg `02_02`, `02_01`, `02_08` and timing byte 0x18, as GT215's `0x100718`, `0x10071c`, `0x100200` |
| `0x10f808` | ramcfg `02_04` and `02_10`, as GT215's `0x111100` |
| `0x10f870` | ramcfg byte 0x0d in every nibble, as Kepler's `ramcfg_11_03_0f` |
| `0x132004` | memory PLL from the VBIOS limits: smallest error, then the highest VCO |
| the rest (`0x10f604`, `0x10f824`, `0x10f830`, `0x10f874`, `0x1373ec`, `0x1373f8`, `0x132018`, `0x100c00`) | one value for the high-speed entry, one for the others (ramcfg `02_04` clear or set) |

The waits after a DLL reset are the DRAM's DLL lock time, 512 clocks, rounded
up to whole microseconds. Every ramcfg flag in the last row changes together on
this board, so which one each register really follows needs a second board.

nouveau's devinit leaves the memory controller in another state than the one
the 390 driver starts from: memory PLL off with bits 1 and 16 of `0x132000`
set, `0x132018` and `0x10f808` with bits the VBIOS init scripts set. A script
that kept bit 1 of `0x132000` corrupted VRAM within seconds of the change; the
390 driver's host code clears both bits before its first script, and so does
0007. Its host code also sets bits 16 and 19 of `0x100c00` at load, which
nothing here does; and around each script it writes `0x10f2fc`, `0x10f254`
and `0x10f2f8`, and bits of `0x10f808` and `0x10f824`, from the CPU, which
0007 leaves out as well.

On the live system, with the series built for 5.15 and reclocking enabled for
the test, every change between 135, 324 and 800 MHz, including 800 → 135 and
135 → 324, which the 390 driver never makes, passes `glmark2 --validate`;
`glmark2` scores 2088 at `0f`, as with the board-specific patch. nouveau's
pstate file still shows 324 MHz memory on the `AC` line at 800: it reads the
memory clock from the PLL only when `0x1373f0` says so, which the GDDR5 path
sets and this one does not.

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
On this laptop nouveau also reports the GPU's VGA output (`card1-VGA-2`) as
connected, and X then extends the desktop onto a monitor that is not there;
`echo off > /sys/class/drm/card1-VGA-2/status` after loading switches it off.

## A new kernel series

DKMS rebuilds the module only for kernels of the series its source came from,
and other kernels boot with their stock nouveau. Under a new series, run the
graphics role again: prepare.sh fetches that series' source and applies the
patches. If a hunk no longer applies, port it on a copy of the new nouveau,
build it against the new headers, and replace the patches in
`roles/graphics/files/nouveau-gf108`; from 5.15 to 7.0 only the clock
subdev's allocation call changed.

## Upstream series

[upstream/](upstream/) holds seven patches for nouveau as in kernel 7.0 that
make the clock and memory code compute what the board-specific patches
hard-code, from the VBIOS, for any GF100-family GPU:

1. keep the PLL / no-PLL flags of each domain from the VBIOS performance table;
2. read the PLL reference divider of domain 7, and the source select's
   second inputs;
3. leave the PLL control's bit 4 clear after the lock test, which otherwise
   bypasses the core PLL;
4. choose PLLs by those flags, let a domain kept off its own PLL borrow domain
   2's, and keep a shared PLL running while a domain uses it;
5. set up the `0x137300` register of the memory script, which a typo left at
   address 0;
6. parse byte 0x0d of the ramcfg entry;
7. a DDR3 path for `gf100_ram_calc`, described [above](#ddr3-from-the-vbios).

On the GF108 here, with reclocking enabled for the test, the shader, domain 7
and domain 8 come out at the 390 driver's clocks at every level, as the clock
counters measure them; each patch builds on its own, and `checkpatch.pl
--strict` finds nothing beyond the sign-off and checks on names nouveau already
uses. They do not enable reclocking on Fermi, which stays off upstream. The
author line is a placeholder: whoever submits them signs them off under their
own name, and the kernel's rules for AI-assisted work want the `Assisted-by`
line they carry.

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
  on the ones it never does. Upstream `calc_clk` ignores both; the series
  above uses them.
- **Memory.** The timing table (version 10) entries 4, 5 and 6, the rammap and
  the ramcfg entries give every value of the memory scripts; see
  [DDR3 from the VBIOS](#ddr3-from-the-vbios).
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
them in the trace showed how they work.

Inputs 2 to 6 of the select give no clock on this board: input 2 chosen at
level 1, and inputs 3 to 6 at the highest level, with all three core PLLs
running, each stopped the domain and took the GPU off the bus until a reboot.
They are not the core PLLs, and nothing here needs them; `read_div` treats
them as no clock. A PLL no domain selects or borrows can be switched off: the
series does so at the lower levels, where the 390 driver keeps them running,
without trouble.

- **The PLLs' reference dividers.** Each PLL's reference passes a divider of
  the same `(src × 2) / (div + 2)` form as the domains' own: SPPLL1 1620 MHz
  through `0x13715c = 0x81200606` gives 405 MHz, and PLL `0x1370e0` (37/14)
  makes 1070 MHz of it, which the counter confirms for domain 7. `read_div`
  skips that divider for domains above 2, and so reports 1620 × 37 / 14 =
  4281 MHz for domain 7.

Still open:

- Opcode `0x34` of the memory scripts, and what `0x13d834` and the `0x3a`
  wait do.
- Which ramcfg flag each high-speed register follows, and the meaning of those
  bits.
- Traces from other GF108 and GF119 boards, which the live ISO and
  [trace-clocks.sh](../trace-clocks.sh) can take; only what is decoded from them
  may be shared.

nouveau's level choice stays manual: it has no governor that follows the load.
On this Optimus laptop the GPU is off whenever nothing renders on it, so a
fixed `0f` behaves much like the 390 driver under load.
