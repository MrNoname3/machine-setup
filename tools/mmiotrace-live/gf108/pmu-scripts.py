#!/usr/bin/env python3
"""pmu-scripts.py [--c] <trace.mmio> [bar0-map-id]

Follows the writes into the PMU's data memory (address port 0x10a1c0, data
port 0x10a1c4) and prints every script uploaded to 0x5800, the script buffer,
decoded as (nwords << 16 | opcode) followed by its arguments. Other data the
driver places there, which does not end in opcode 0x16, is left out. MARK lines
are printed where they fall, so each script sits in the step that sent it.

With --c, each script is printed as a C array of its raw words instead, named
after the MARK before it and its place after that MARK.
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


def c_array(name, words):
    lines = [f"static const u32 {name}[] = {{"]
    for i in range(0, len(words), 6):
        lines.append("\t" + " ".join(f"0x{w:08x}," for w in words[i:i + 6]))
    lines.append("};")
    return "\n".join(lines)


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
    args = sys.argv[1:]
    as_c = "--c" in args
    args = [a for a in args if a != "--c"]
    path = args[0]
    bar0 = args[1] if len(args) > 1 else "3"
    addr = 0
    block_start = None
    block = []
    mark = "start"
    count = 0

    def flush():
        nonlocal block_start, block, count
        if block_start == SCRIPT and ends_script(block):
            if not as_c:
                print(f"  script ({len(block)} words)")
                print("\n".join(decode(block)))
            else:
                count += 1
                print(f"/* after \"{mark}\", script {count} */")
                print(c_array(f"script_{''.join(c if c.isalnum() else '_' for c in mark)}_{count}", block))
        block_start, block = None, []

    with open(path, errors="replace") as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            if p[0] == "MARK":
                flush()
                mark, count = " ".join(p[2:]), 0
                if not as_c:
                    print(f"== {mark}")
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
