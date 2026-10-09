#!/usr/bin/env python3
"""ddr3-model.py <pmu-scripts-390.txt>
ddr3-model.py --live <registers> <MHz> <dmesg>

The DDR3 memory clock change of upstream patch 0007, in Python, computed from
this board's VBIOS entries. The first form checks it against the four scripts
of pmu-scripts-390.txt, each from the register state the 390 driver left before
it: the boot reads, the earlier scripts' writes and the host's own writes in
between. The second checks nouveau's memx output (debug=pmu=debug,
config=NvMemExec=0) against the sequence computed from the registers read
before the change (nvreg lines: "<address> <value>").
"""
import sys

# ---- VBIOS data of the Aspire 5750G (strap 6) -----------------------------
TIMING = {
    135: "05 04 06 0b 00 20 00 06 00 03 03 03 05 0a 00 00 00 00 04 05 07 03 00 00 04",
    324: "0e 04 06 2e 00 92 00 0d 00 06 06 06 05 0a 00 00 00 00 05 05 0f 03 00 00 04",
    800: "0e 07 0c 2e 00 92 00 22 00 0e 0e 0e 07 16 00 00 00 00 07 09 28 05 00 00 04",
}
RAMMAP = {
    135: "00 00 a2 00 0a 05 02 70 02 88 88 00 00 00",
    324: "a3 00 c2 01 0a 05 02 70 02 88 88 00 00 00",
    800: "c3 01 e8 03 43 20 40 fc 05 88 88 00 00 00",
}
RAMCFG = {
    135: "00 04 7f 10 00 9f 9f 10 10 04 00 00 00 00",
    324: "00 05 3f 10 00 88 8c 10 10 04 00 00 00 00",
    800: "00 06 20 00 00 00 00 00 00 00 00 00 00 0a",
}
PLL = dict(ref=405000, vmin=1250000, vmax=2500000, imin=50000, imax=100000,
           mmin=6, mmax=11, nmin=13, nmax=48, pmin=1, pmax=63)


def b(s):
    return bytes.fromhex(s.replace(" ", ""))


class Cfg:
    def __init__(self, mhz):
        t, rm, rc = b(TIMING[mhz]), b(RAMMAP[mhz]), b(RAMCFG[mhz])
        self.khz = mhz * 1000
        (self.WR, self.WTR, self.CL, self.RC, self.RFC, self.RAS, self.RP,
         self.RCDRD, self.RCDWR, self.RRD, self.T13) = (
            t[0], t[1], t[2], t[3], t[5], t[7], t[9], t[10], t[11], t[12], t[13])
        self.ODT = t[14] & 7
        self.T18, self.CWL, self.T20, self.T21, self.T24 = t[18], t[19], t[20], t[21], t[24]
        self.rammap_04_02 = bool(rm[4] & 0x02)
        self.rammap_04_08 = bool(rm[4] & 0x08)
        self.c05, self.c06, self.c07, self.c08 = rc[5], rc[6], rc[7], rc[8]
        self.c02 = {bit: bool(rc[2] & bit) for bit in (0x01, 0x02, 0x04, 0x08, 0x10, 0x20)}
        self.DLLoff = bool(rc[2] & 0x40)
        self.c0d = rc[0x0d]
        # the high-speed class: everything the blob switches between 324 and 800
        self.hs = not self.c02[0x04]


def pll_calc(khz, p=PLL):
    """Smallest error; on a tie the highest P (VCO), then the smallest M."""
    best = None
    for P in range(min(p['vmax'] // khz, p['pmax']), p['pmin'] - 1, -1):
        for M in range(p['mmin'], p['mmax'] + 1):
            if not p['imin'] <= p['ref'] // M <= p['imax']:
                continue
            N, rem = divmod(khz * P * M, p['ref'])
            if rem >= p['ref'] // 2:
                N += 1
            if not p['nmin'] <= N <= p['nmax']:
                continue
            vco = p['ref'] * N // M
            if not p['vmin'] <= vco <= p['vmax']:
                continue
            err = abs(khz - vco // P)
            if best is None or err < best[0]:
                best = (err, P, N, M)
    _, P, N, M = best
    return P << 16 | N << 8 | M


# DDR3 mode register encodings (nvkm sddr3.c)
XL_CL = {5: 2, 6: 4, 7: 6, 8: 8, 9: 10, 10: 12, 11: 14, 12: 1, 13: 3, 14: 5}
XL_WR = {5: 1, 6: 2, 7: 3, 8: 4, 10: 5, 12: 6, 14: 7, 15: 7, 16: 0}
XL_CWL = {5: 0, 6: 1, 7: 2, 8: 3, 9: 4, 10: 5}


def sddr3(cfg, mr0, mr1, mr2):
    CL, WR, CWL = XL_CL[cfg.CL], XL_WR[cfg.WR], XL_CWL[cfg.CWL]
    mr0 = (mr0 & ~0xf74) | (WR & 7) << 9 | (CL & 0x0e) << 3 | (CL & 1) << 2
    mr1 = (mr1 & ~0x245) | (cfg.ODT & 1) << 2 | (cfg.ODT & 2) << 5 | (cfg.ODT & 4) << 7 | cfg.DLLoff
    mr2 = (mr2 & ~0x038) | (CWL & 7) << 3
    return mr0, mr1, mr2


class Fuc:
    """ramfuc: a cached register file and the memx command list."""
    def __init__(self, regs):
        self.regs, self.ops, self.force = regs, [], set()
        self.pending = 0

    def rd(self, a):
        return self.regs[a]

    def wr(self, a, v):
        self.regs[a] = v
        self.ops.append(('wr', a, v))
        if 0x10f600 <= a < 0x10f900:
            self.pending += 1

    def nuke(self, a):
        self.force.add(a)

    def mask(self, a, m, d):
        t = self.regs[a]
        n = (t & ~m) | d
        if n != t or a in self.force:
            self.wr(a, n)
            self.force.discard(a)
            return True
        return False

    def nsec(self, n):
        self.ops.append(('nsec', n))

    def wait(self, a, m, d, n):
        self.ops.append(('wait', a, m, d, n))

    def sync(self, n=None):
        self.wr(0x13d834, 0)
        self.ops.append(('sync', self.pending))
        self.pending = 0


def tdllk(khz):
    """512 clocks of DLL lock time, in whole microseconds."""
    ns = (512 * 1000000 + khz - 1) // khz
    return (ns + 999) // 1000 * 1000


def calc(fuc, next):
    f = fuc
    from_pll = f.rd(0x132000) & 1
    hs_from = bool(f.rd(0x1373ec) & 0x00020000)
    hs_to = next.hs
    up = hs_to and not hs_from
    coef = pll_calc(next.khz)
    mr = [f.rd(0x10f300), f.rd(0x10f304), f.rd(0x10f320)]
    dll_was_off = mr[1] & 1
    mr0, mr1, mr2 = sddr3(next, *mr)

    def lock_pll():
        f.wr(0x137320, f.rd(0x137320))
        f.wr(0x137330, f.rd(0x137330))
        f.wr(0x132004, coef)
        f.mask(0x132000, 0x00000001, 0x00000001)
        f.wait(0x137390, 0x00000002, 0x00000002, 64000)

    r132018 = 0x00005000 if hs_to else 0x10001000

    if not from_pll:
        f.mask(0x132000, 0x00010002, 0x00000000)
        lock_pll()
        f.mask(0x132018, 0x1000f000, r132018)
    else:
        f.wr(0x137300, f.rd(0x137300))
    f.wr(0x137370, 1)
    f.wr(0x137380, 1)
    if hs_from or hs_to:
        sync = f.mask(0x10f808, 0x40000000, 0x40000000)
        sync |= f.mask(0x10f824, 0x00000780 | (0x6000 if not from_pll and hs_to else 0), 0)
        if sync:
            f.sync(2)

    f.wr(0x100b0c, 0x00080012)
    f.ops.append(('vblank',))
    f.wr(0x611200, 0x00003300)
    f.ops.append(('block',))

    f.mask(0x10f200, 0x00000800, 0x00000000)
    if hs_to and f.mask(0x10f808, 0x04000000, 0x04000000):
        f.sync(1)
    if next.DLLoff and not dll_was_off:
        f.wr(0x10f314, 1)
        f.mask(0x10f304, 0x00000001, 0x00000001)
        f.nsec(1000)
    if hs_to:
        f.mask(0x1373ec, 0x00030000, 0x00020000)
    rfc = next.RFC << 8
    if rfc > (f.rd(0x10f290) & 0x0000ff00):
        f.mask(0x10f290, 0x0000ff00, rfc)
    f.wr(0x10f314, 1)
    f.wr(0x10f210, 0)
    f.wr(0x10f310, 1)
    f.wr(0x10f310, 1)
    f.nsec(1000)
    f.wr(0x10f090, 0x00000060)
    f.wr(0x10f090, 0xc000007e)

    if from_pll:
        f.mask(0x137360, 0x00000001, 0x00000001)
        if not hs_to and f.mask(0x10f830, 0x00000006, 0x00000006):
            f.sync(1)
        f.wr(0x137370, 0)
        f.wr(0x137380, 0)
        f.mask(0x132018, 0x0000c000, 0x00000000)
        f.mask(0x132000, 0x00000001, 0x00000000)
        lock_pll()

    # phase A
    sync = f.mask(0x10f874, 0x04000000, 0 if hs_to else 0x04000000)
    if next.rammap_04_08:
        f.wr(0x10f658, next.c06 << 16 | next.c05 << 8 | next.c05)
        sync = True
    if hs_to:
        sync |= f.mask(0x10f824, 0x00006000, 0)
    # phase B
    if f.rd(0x132018) & 0x1000f000 != r132018:
        if sync:
            f.sync(2)
        sync = False
        f.mask(0x132018, 0x1000f000, r132018)
    if up:
        f.nsec(20000)
    if next.rammap_04_08:
        f.wr(0x10f660, next.c08 << 8 | next.c07)
        sync = True
    train = 0 if next.rammap_04_08 else 0x00002000
    f.mask(0x10f910, 0xffffffff, train)
    f.mask(0x10f914, 0xffffffff, train)
    if not next.rammap_04_08:
        f.wr(0x10f658, 0)
        sync = True
    if not hs_to:
        sync |= f.mask(0x10f824, 0x00006000, 0x00006000)
    else:
        sync |= f.mask(0x10f830, 0x00000006, 0)
    if sync:
        f.sync(3)

    f.wr(0x137370, 1)
    f.wr(0x137380, 1)
    f.mask(0x137360, 0x00000001, 0x00000000)
    f.wr(0x10f090, 0x4000007f)
    f.wr(0x10f210, 0x80000000)
    f.nsec(tdllk(next.khz))

    def dll_reset():
        f.nuke(0x10f300)
        f.mask(0x10f300, 0x00000100, 0x00000100)
        f.nsec(1000)
        f.mask(0x10f300, 0x00000100, 0x00000000)
        f.nsec(1000)

    if not next.DLLoff:
        if f.mask(0x10f304, 0xffffffff, mr1):
            f.nsec(1000)
        dll_reset()
    if f.mask(0x10f320, 0x00000fff, mr2 & 0xfff):
        f.nsec(1000)
    if f.mask(0x10f304, 0xffffffff, mr1):
        f.nsec(1000)
    f.wr(0x10f300, mr0)
    f.nsec(1000)

    f.mask(0x10f224, 0x001f0000, next.T18 << 16)
    f.mask(0x10f290, 0xffffffff, next.RP << 24 | (next.RAS & 0x7f) << 17 | next.RFC << 8 | next.RC)
    cl = next.CL - 1 if next.DLLoff else next.CL
    f.mask(0x10f294, 0x00ffffff, next.RCDWR << 20 | next.RCDRD << 14 | next.CWL << 7 | cl)
    f.mask(0x10f298, 0x007f1f00, next.WR << 16 | next.WTR << 8)
    f.mask(0x10f29c, 0x0000ffff, next.T20 << 9 | next.T21 << 5 | next.T13)
    f.mask(0x10f2a0, 0x000f8000, next.RRD << 15)
    sync = f.mask(0x10f200, 0x00001000, 0 if next.c02[0x08] else 0x00001000)
    sync |= f.mask(0x10f604, 0xf1000000, (0xf0000000 if next.c02[0x20] else 0) |
                   (0x01000000 if not next.c02[0x04] else 0))
    t24 = next.T24 << 28
    sync |= f.mask(0x10f614, 0xf0000100, t24 | next.c02[0x01] << 8)
    sync |= f.mask(0x10f610, 0xf0000100, t24 | next.c02[0x02] << 8)
    if next.c02[0x04]:
        r808 = 0x08000004 if next.c02[0x10] else 0x00000024
    else:
        r808 = 0x16900000 | (0x08000000 if next.c02[0x10] else 0)
    sync |= f.mask(0x10f808, 0x1e900024, r808)
    if sync:
        f.sync(4)

    sync = False
    if not hs_to:
        sync |= f.mask(0x1373ec, 0x00030000, 0)
    sync |= f.mask(0x1373f8, 0x00000001, 0 if hs_to else 1)
    f.wr(0x10f870, 0x11111111 * next.c0d)
    if sync:
        f.sync(1)
    f.mask(0x100c00, 0x08000000, 0 if hs_to else 0x08000000)

    if not next.DLLoff:
        dll_reset()
        f.nsec(tdllk(next.khz))
    else:
        f.nsec(tdllk(next.khz) + 1000)

    if hs_from and not hs_to:
        for v in (0x3cb, 0x6cb, 0x1cb, 0x3ca, 0x6ca, 0x1ca):
            f.wr(0x10f324, v)
    f.mask(0x10f830, 0x01000000, 0x01000000)
    f.mask(0x10f830, 0x01000000, 0x00000000)

    f.ops.append(('unblock',))
    f.sync(3)
    f.wr(0x100b0c, 0x00080028)
    f.wr(0x611200, 0x00003330)
    if next.rammap_04_02:
        f.mask(0x10f200, 0x00000800, 0x00000800)


# ---- the blob scripts -------------------------------------------------------
def parse(path):
    scripts, cur = [], None
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == 'script':
            cur = []
            scripts.append(cur)
            continue
        if not p[0].startswith('op') or cur is None:
            continue
        op = int(p[0][2:], 16)
        if op == 0x21:
            for pair in p[2:]:
                a, v = pair.split('=')
                cur.append(('wr', int(a, 16), int(v, 16)))
        else:
            cur.append((op, [int(x, 16) for x in p[1:]]))
    return scripts


def blob_ops(raw):
    """The blob script in the model's terms (what the board patch emits)."""
    out, wd, wa = [], 0, 0
    for op in raw:
        if op[0] == 'wr':
            out.append(op)
            continue
        code, args = op
        if code == 0x00:
            wd = args[0]
        elif code == 0x01:
            wa = args[0]
        elif code == 0x15:
            out.append(('wait', wa, args[0], wd, args[1]))
        elif code == 0x14:
            if args[0] == 0:
                out.append(('vblank',))
        elif code == 0x20:
            out.append(('block',) if args[0] else ('unblock',))
        elif code == 0x2e:
            out.append(('nsec', args[0]))
        elif code == 0x3a:
            out.append(('sync', args[0]))
    return out


def fmt(op):
    if op[0] == 'wr':
        return f"{op[1]:06x}={op[2]:08x}"
    if op[0] == 'wait':
        return f"wait {op[1]:06x}&{op[2]:x}=={op[3]:x} {op[4]}"
    return ' '.join(str(x) for x in op)


def compare(name, mine, blob):
    import difflib
    a = [fmt(o) for o in blob]
    m = [fmt(o) for o in mine]
    # sync arguments are compared apart from the rest, and listed when they differ
    na = [x if not x.startswith('sync') else 'sync' for x in a]
    nm = [x if not x.startswith('sync') else 'sync' for x in m]
    diff = list(difflib.unified_diff(na, nm, 'blob', 'model', lineterm='', n=2))
    syncs = [(x, y) for x, y in zip([x for x in a if x.startswith('sync')],
                                    [y for y in m if y.startswith('sync')]) if x != y]
    print(f"== {name}: {len(blob)} blob ops, {len(mine)} model ops, "
          f"{'IDENTICAL' if not diff else 'DIFFERENT'}"
          f"{'' if not syncs else ', sync args ' + str(syncs)}")
    for d in diff[2:]:
        print('   ', d)


def main():
    raw = parse(sys.argv[1])
    # the four clock changes, without the two 7-word display scripts
    big = [s for s in raw if len(s) > 10][:4]

    regs = {
        0x100b0c: 0x00080028, 0x100c00: 0x0c090124, 0x10f200: 0x00028800,
        0x10f224: 0x0c050a07, 0x10f290: 0x061a922e, 0x10f294: 0x4c618286,
        0x10f298: 0x440e0411, 0x10f29c: 0x00001e6a, 0x10f2a0: 0x42e28069,
        0x10f300: 0x00001e20, 0x10f304: 0x00100002, 0x10f320: 0x00200080,
        0x10f604: 0xf0000000, 0x10f610: 0x40044f77, 0x10f614: 0x40044f77,
        0x10f658: 0x008c8888, 0x10f660: 0x00001010, 0x10f808: 0x08020004,
        0x10f824: 0x004279e7, 0x10f830: 0x00000017, 0x10f870: 0x00000000,
        0x10f874: 0x04000000, 0x10f910: 0x00000000, 0x10f914: 0x00000000,
        0x132000: 0x18030001, 0x132004: 0x00051806, 0x132018: 0x10001000,
        0x137300: 0x00000103, 0x137320: 0x00000103, 0x137330: 0x81200606,
        0x137360: 0x00000002, 0x137370: 0x00000001, 0x137380: 0x00000001,
        0x1373ec: 0x00000d0d, 0x1373f8: 0x00002055, 0x13d834: 0, 0x10f324: 0,
    }
    # host writes before each script, and after the previous one (trace order)
    host_before = [
        {0x137360: 0x3, 0x132000: 0x18000000},                      # mclk off the PLL
        {0x10f824: 0x00421e67},                                      # after reaching 800
        {0x132018: 0x10001000, 0x10f824: 0x004279e7, 0x10f808: 0x08020004},
        {0x132018: 0x10001000, 0x10f824: 0x004279e7, 0x10f808: 0x08020004},
    ]
    names = ["boot -> 800", "800 -> 324", "324 -> 135", "135 -> 800"]
    targets = [800, 324, 135, 800]
    for i, script in enumerate(big):
        regs.update(host_before[i])
        before = dict(regs)
        fuc = Fuc(dict(before))
        calc(fuc, Cfg(targets[i]))
        compare(names[i], fuc.ops, blob_ops(script))
        for op in script:          # the state the blob left
            if op[0] == 'wr':
                regs[op[1]] = op[2]
        if regs[0x132000] & 1:     # status bits the PLL sets once locked
            regs[0x132000] |= 0x00030000



# ---- checking nouveau's memx output (debug=pmu=debug, NvMemExec=0) ---------
def memx_ops(lines):
    """Turns memx debug lines into the model's op list."""
    import re
    out = []
    for line in lines:
        if m := re.search(r'R\[([0-9a-f]{6})\] = ([0-9a-f]{8})', line):
            out.append(('wr', int(m[1], 16), int(m[2], 16)))
        elif m := re.search(r'R\[([0-9a-f]{6})\] & ([0-9a-f]{8}) == ([0-9a-f]{8}), (\d+)', line):
            out.append(('wait', int(m[1], 16), int(m[2], 16), int(m[3], 16), int(m[4])))
        elif m := re.search(r'DELAY = (\d+) ns', line):
            out.append(('nsec', int(m[1])))
        elif 'WAIT VBLANK' in line:
            out.append(('vblank',))
        elif 'HOST BLOCKED' in line:
            out.append(('block',))
        elif 'HOST UNBLOCKED' in line:
            out.append(('unblock',))
    return out


def as_memx(ops):
    """The model's ops as memx sees them: a sync is a delay of 10us per write."""
    out = []
    for op in ops:
        if op[0] == 'sync':
            if op[1]:
                out.append(('nsec', op[1] * 10000))
        else:
            out.append(op)
    return out


def check_live(regs_path, mhz, dmesg_path):
    regs = {}
    for line in open(regs_path):
        p = line.split()
        if len(p) == 2 and len(p[0]) == 6:
            try:
                regs[int(p[0], 16)] = int(p[1], 16)
            except ValueError:
                pass
    fuc = Fuc(dict(regs))
    calc(fuc, Cfg(mhz))
    compare(f"live -> {mhz}", as_memx(fuc.ops), memx_ops(open(dmesg_path)))


if __name__ == '__main__' and len(sys.argv) == 5 and sys.argv[1] == '--live':
    check_live(sys.argv[2], int(sys.argv[3]), sys.argv[4])
    sys.exit(0)


if __name__ == '__main__':
    main()
