# GF108 (GeForce GT 520M) clock changes

What the NVIDIA 390 driver does to move a GF108 between its performance levels,
recorded with [trace-clocks.sh](../trace-clocks.sh), and how far nouveau gets
with the same hardware. The levels, from the VBIOS, as core/memory MHz:

| Level | 390 driver | nouveau pstate |
|---|---|---|
| 0 | 50 / 135 | `03` |
| 1 | 202 / 324 | `07` |
| 2 | 672 / 800 | `0f` |

## Core clocks

nouveau has code to change GF100-family clocks but creates the clock subdev
with reclocking disabled, so a pstate write returns `ENOSYS`
([0001-gf100-allow-reclock.patch](0001-gf100-allow-reclock.patch) enables it).
With it enabled, `0f` reports 670 MHz but leaves the GPU in a state that is
slower than `07` and soon stops answering: the domains nouveau programs differ
from the 390 driver's ([clock-block-states.txt](clock-block-states.txt), the
last value seen for each register in each state):

- **0x1370e0** feeds domains 7, 8, 9 and 14. The 390 driver keeps it running;
  nouveau switches it off when domain 7 can run from a divider, then tries to
  move domain 8 onto it, and the source select never acknowledges.
- **Domain 8** runs from the fixed 100 MHz source at level 2
  (`0x137180 = 0x07000102`); nouveau runs it from SPPLL1 undivided.
- **The gpc PLL** takes its reference from SPPLL0/4 (`0x137120 = 0x1003`);
  nouveau leaves SPPLL1 selected.

[replay-blob-L2-core.nvreg](replay-blob-L2-core.nvreg) and
[replay-blob-L0-core.nvreg](replay-blob-L0-core.nvreg) put the clock block into
the 390 driver's level 2 and level 0 states with [nvreg](../nvreg.c), under a
loaded nouveau, memory untouched. Switching back and forth is repeatable and
fault-free, and a full `glmark2` run passes at level 2. With
[bench.sh](bench.sh) (PRIME offload, memory at 324 MHz throughout):

| Core | glmark2 score |
|---|---|
| 50 MHz (replayed level 0) | 348 |
| 202 MHz (nouveau's boot state) | 739 |
| 670 MHz (replayed level 2) | 899 |

## Memory clocks

The 390 driver does not write the memory controller from the CPU. It uploads a
script into the PMU's data memory (address port `0x10a1c0`, data port
`0x10a1c4`, buffer at `0x5800`) and the PMU runs it with DRAM in self-refresh.
[pmu-scripts.py](pmu-scripts.py) pulls the scripts out of a trace;
[pmu-scripts-390.txt](pmu-scripts-390.txt) holds every one from a full cycle.
Each command is a header `(nwords << 16) | opcode` and its arguments:

| Opcode | Arguments | Reading |
|---|---|---|
| `21` | address/value pairs | register writes |
| `2e` | ns | delay |
| `00`, `01`, `15` | value; address; mask, timeout | wait for `(reg & mask) == value` |
| `20`, `34`, `14`, `3a` | – | not identified yet (around blanking and blocking the GPU) |
| `16` | – | end |

The level-change scripts are identical each time they run, and DDR3-specific:
mode register writes through `0x10f300`/`0x10f320`, timings in `0x10f224` and
`0x10f290`–`0x10f2a0`, the memory PLL at `0x132000`/`0x132004`.

## Next

- Teach nouveau's `gf100_clk_calc` the 390 driver's choices: keep the shared
  PLL running, the domain 8 source, the gpc PLL reference.
- Run the DDR3 sequence through nouveau's own PMU script engine (`ramgf100`
  through memx), whose existing sequence is written for GDDR5.
