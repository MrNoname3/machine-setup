#!/usr/bin/env python3
"""pmu-scripts.py <trace.mmio> [bar0-map-id]

Follows the writes into the PMU's data memory (address port 0x10a1c0, data
port 0x10a1c4) and prints every script uploaded to 0x5800, the script buffer,
decoded as (nwords << 16 | opcode) followed by its arguments. Other data the
driver places there, which does not end in opcode 0x16, is left out. MARK lines
are printed where they fall, so each script sits in the step that sent it.
"""
import sys

BAR0 = 0xd0000000
SCRIPT = 0x5800


def decode(words):
    i = 0
    out = []
    while i < len(words):
        hdr = words[i]
        n, op = hdr >> 16, hdr & 0xffff
        if n == 0 or i + n > len(words):
            out.append(f"    ?? {' '.join(f'{w:08x}' for w in words[i:])}")
            break
        args = words[i + 1:i + n]
        if op == 0x21 and len(args) % 2 == 0:
            pairs = ' '.join(f"{args[j]:06x}={args[j + 1]:08x}" for j in range(0, len(args), 2))
            out.append(f"    op21 wr   {pairs}")
        else:
            out.append(f"    op{op:02x}      {' '.join(f'{a:08x}' for a in args)}")
        i += n
    return out


def ends_script(words):
    i = 0
    while i < len(words):
        n = words[i] >> 16
        if n == 0:
            return False
        if words[i] & 0xffff == 0x16:
            return True
        i += n
    return False


def main():
    path = sys.argv[1]
    bar0 = sys.argv[2] if len(sys.argv) > 2 else "3"
    addr = 0
    block_start = None
    block = []

    def flush():
        nonlocal block_start, block
        if block_start == SCRIPT and ends_script(block):
            print(f"  script ({len(block)} words)")
            print("\n".join(decode(block)))
        block_start, block = None, []

    with open(path, errors="replace") as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            if p[0] == "MARK":
                flush()
                print(f"== {' '.join(p[2:])}")
                continue
            if p[0] != "W" or p[3] != bar0:
                continue
            off = int(p[4], 16) - BAR0
            val = int(p[5], 16)
            if off == 0x10a1c0:
                flush()
                addr = val & 0xfffc
                block_start = addr
            elif off == 0x10a1c4:
                block.append(val)
                addr += 4
    flush()


if __name__ == "__main__":
    main()
