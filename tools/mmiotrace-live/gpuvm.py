#!/usr/bin/env python3
"""gpuvm.py [--big 16|17] <channel> <va> <len> [out]

Reads <len> bytes at virtual address <va> of a Fermi (GF100-family) GPU address
space, walking its page tables: <channel> is an instance block in the falcon
CHANNEL_CUR format (bits 0-27 the address >> 12, bits 28-29 its target), as a
falcon's +0x050 register reports it. VRAM is read with ./pramin, system memory
through /proc/kcore (kcore.py beside this script). Pages that are not mapped
read as zero and are listed on stderr. Writes to <out>, or prints the PTEs.

Formats, as nouveau writes them (vmmgf100.c): instance +0x200 holds the page
directory's address and target; a PDE is 8 bytes, the big-page table in its
low word and the small-page table in its high word, each (address >> 8) with
the target in bits 0-1; a PTE is 8 bytes, (address >> 8) | valid in the low
word, the target in bits 0-1 of the high word. Targets: 0 or 1 VRAM, 2 and 3
system memory. A PDE spans 1024 big pages: --big 17 (128 KiB) or 16 (64 KiB),
whichever the driver chose.
"""
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import kcore  # noqa: E402


def vram(addr, length):
    return subprocess.run([os.path.join(HERE, 'pramin'), 'dump', hex(addr), hex(length)],
                          check=True, capture_output=True).stdout


def mem(target, addr, length, kf):
    return vram(addr, length) if target in (0, 1) else kcore.read(kf, addr, length)


def u64(target, addr, kf):
    return struct.unpack('<Q', mem(target, addr, 8, kf))[0]


def main():
    a = sys.argv[1:]
    big = 17
    if a[:1] == ['--big']:
        big, a = int(a[1]), a[2:]
    if len(a) not in (3, 4):
        sys.exit(__doc__)
    chan, va, length = (int(x, 0) for x in a[:3])
    out = a[3] if len(a) == 4 else None

    with open('/proc/kcore', 'rb') as kf:
        inst_t, inst = chan >> 28 & 3, (chan & 0x0fffffff) << 12
        pd = u64(inst_t, inst + 0x200, kf)
        pd_t, pd_a = pd & 3, pd & ~0xfff
        data, missing = bytearray(), []
        page = va & ~0xfff
        while page < va + length:
            pde = u64(pd_t, pd_a + (page >> (big + 10)) * 8, kf)
            lo, hi = pde & 0xffffffff, pde >> 32
            pte = 0
            if hi & 3:                                  # small pages
                index = (page >> 12) & ((1 << (big - 2)) - 1)
                pte = u64(hi & 3, ((hi & ~0xf) << 8) + index * 8, kf)
            if not pte & 1 and lo & 3:                  # big pages
                pte = u64(lo & 3, ((lo & ~0xf) << 8) + ((page >> big) & 0x3ff) * 8, kf)
                if pte & 1:
                    pte += (page & ((1 << big) - 1)) >> 8   # the 4 KiB page within it
            if pte & 1:
                t, addr = pte >> 32 & 3, (pte & 0xfffffff0) << 8
                if out is None:
                    print(f'va 0x{page:x} -> {"vram" if t < 2 else "sys"} 0x{addr:x}')
                chunk = mem(t, addr, 0x1000, kf)
            else:
                missing.append(page)
                chunk = bytes(0x1000)
            data += chunk
            page += 0x1000
    if out:
        start = va & 0xfff
        open(out, 'wb').write(data[start:start + length])
    if missing:
        print('unmapped:', ' '.join(f'0x{p:x}' for p in missing), file=sys.stderr)


if __name__ == '__main__':
    main()
