#!/usr/bin/env python3
"""kcore.py find <hex bytes> | read <phys> <len> [out]

Searches or reads system RAM through /proc/kcore (root), which maps all of it in
the kernel's direct map; the program headers give each segment's physical
address. `find` prints the physical address of every match. Its own pattern
sits in this process's memory too, so it shows up as a match as well: read a
hit back, from a separate run, before believing it. `read` writes the bytes at
a physical address to a file, or as hex to stdout.
"""
import struct
import sys

DIRECT_MAP = (0xffff888000000000, 0xffffc88000000000)
CHUNK = 64 << 20


def segments(f):
    f.seek(0)
    eh = f.read(64)
    phoff = struct.unpack_from('<Q', eh, 0x20)[0]
    phentsize, phnum = struct.unpack_from('<HH', eh, 0x36)
    f.seek(phoff)
    for _ in range(phnum):
        typ, _, off, vaddr, paddr, filesz, _, _ = struct.unpack('<IIQQQQQQ', f.read(phentsize))
        if typ == 1 and DIRECT_MAP[0] <= vaddr < DIRECT_MAP[1]:
            yield off, paddr, filesz


def find(f, pat):
    for off, paddr, size in list(segments(f)):
        pos = 0
        while pos < size:
            f.seek(off + pos)
            try:
                buf = f.read(min(CHUNK + len(pat), size - pos))
            except OSError:
                pos += CHUNK
                continue
            i = buf.find(pat)
            while i >= 0:
                print(f'0x{paddr + pos + i:x}', flush=True)
                i = buf.find(pat, i + 1)
            pos += CHUNK


def read(f, phys, length):
    for off, paddr, size in list(segments(f)):
        if paddr <= phys and phys + length <= paddr + size:
            f.seek(off + phys - paddr)
            return f.read(length)
    sys.exit(f'0x{phys:x} is not in the direct map')


def main():
    a = sys.argv[1:]
    with open('/proc/kcore', 'rb') as f:
        if len(a) == 2 and a[0] == 'find':
            find(f, bytes.fromhex(a[1]))
        elif len(a) in (3, 4) and a[0] == 'read':
            data = read(f, int(a[1], 0), int(a[2], 0))
            if len(a) == 4:
                open(a[3], 'wb').write(data)
            else:
                print(data.hex())
        else:
            sys.exit(__doc__)


if __name__ == '__main__':
    main()
