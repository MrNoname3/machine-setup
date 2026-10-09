#!/usr/bin/env python3
"""falcon-image.py <out-prefix> <dump-prefix>...

Turns falcon-dump.sh output into binary images: <dump>-imem.bin and
<dump>-dmem.bin for each dump, and <out>-virt.bin, the code laid out by
virtual address, merged from every dump. A falcon with code paging keeps only
some pages resident, and dumps taken at different moments hold different ones;
pages none of them held stay zero, and the list of them is printed. Disassemble
the result with envydis.sh (-m falcon -V fuc3 for a Fermi falcon).
"""
import struct
import sys


def words(path):
    return [int(x, 16) for x in open(path).read().split()]


def main():
    out, dumps = sys.argv[1], sys.argv[2:]
    if not dumps:
        sys.exit(__doc__)
    pages = {}
    for d in dumps:
        for kind in ('imem', 'dmem'):
            w = words(f'{d}-{kind}.txt')
            open(f'{d}-{kind}.bin', 'wb').write(struct.pack(f'<{len(w)}I', *w))
        code = open(f'{d}-imem.bin', 'rb').read()
        for phys, tlb in enumerate(words(f'{d}-tlb.txt')):
            if not tlb >> 24 & 7:          # no valid, busy or secret flag
                continue
            virt = tlb >> 8 & 0xffff
            page = code[phys * 256:(phys + 1) * 256]
            if virt in pages and pages[virt] != page:
                print(f'virtual page 0x{virt:x} differs between dumps; keeping the first')
            pages.setdefault(virt, page)
    top = max(pages) + 1
    image = bytearray(top * 256)
    for virt, page in pages.items():
        image[virt * 256:(virt + 1) * 256] = page
    open(f'{out}-virt.bin', 'wb').write(image)
    missing = [v for v in range(top) if v not in pages]
    print(f'{out}-virt.bin: {len(pages)} of {top} virtual pages')
    if missing:
        runs, start = [], missing[0]
        for a, b in zip(missing, missing[1:] + [None]):
            if b != a + 1:
                runs.append(f'0x{start:x}' if start == a else f'0x{start:x}-0x{a:x}')
                start = b
        print('missing:', ' '.join(runs))


if __name__ == '__main__':
    main()
