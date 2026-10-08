#!/usr/bin/env python3
"""pmu-scripts.py [--c | --header PREFIX [--mhz REPORTED=NAME]...] <trace.mmio> [bar0-map-id]

Follows the writes into the PMU's data memory (address port 0x10a1c0, data
port 0x10a1c4) and prints every script uploaded to 0x5800, the script buffer,
decoded as (nwords << 16 | opcode) followed by its arguments. Other data the
driver places there, which does not end in opcode 0x16, is left out. MARK lines
are printed where they fall, so each script sits in the step that sent it.

With --c, each script is printed as a C array of its raw words instead, named
after the MARK before it and its place after that MARK.

With --header, the memory clock scripts (those that set the memory PLL's
coefficients, 0x132004) become a C header of arrays named
PREFIX_<from>_<to>, one per distinct change: <to> is the memory clock the next
"level ... clocks <core>,<memory>" MARK reports, <from> the one before it, or
"boot" for the first. --mhz renames a reported clock, as in --mhz 793=800.
"""
import re
import sys

BAR0 = 0xd0000000
SCRIPT = 0x5800
LEVEL = re.compile(r"level \d+ clocks \d+,(\d+)")


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


def commands(words):
    i = 0
    while i < len(words):
        n = words[i] >> 16
        if n == 0:
            return
        yield words[i] & 0xffff, words[i + 1:i + n]
        i += n


def ends_script(words):
    return any(op == 0x16 for op, _ in commands(words))


def sets_memory_pll(words):
    return any(op == 0x21 and 0x132004 in args[0::2] for op, args in commands(words))


def events(path, bar0):
    """The trace's MARKs, as ("mark", text), and scripts, as ("script", words)."""
    block_start, block = None, []

    def flush():
        nonlocal block_start, block
        if block_start == SCRIPT and ends_script(block):
            yield "script", block
        block_start, block = None, []

    with open(path, errors="replace") as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            if p[0] == "MARK":
                yield from flush()
                yield "mark", " ".join(p[2:])
                continue
            if p[0] != "W" or p[3] != bar0:
                continue
            off = int(p[4], 16) - BAR0
            if off == 0x10a1c0:
                yield from flush()
                block_start = int(p[5], 16) & 0xfffc
            elif off == 0x10a1c4:
                block.append(int(p[5], 16))
    yield from flush()


def header(evs, prefix, mhz):
    changes = {}
    pending = []
    current = "boot"
    for kind, data in evs:
        if kind == "script" and sets_memory_pll(data):
            pending.append(data)
        elif kind == "mark" and pending and (m := LEVEL.search(data)):
            target = mhz.get(m.group(1), m.group(1))
            for words in pending:
                key = (current, target)
                if key in changes and changes[key] != words:
                    sys.exit(f"pmu-scripts.py: two different scripts for {current} -> {target}")
                changes.setdefault(key, words)
            pending, current = [], target
    guard = f"__{prefix.upper()}_H__"
    out = ["/* SPDX-License-Identifier: MIT */",
           "/* Memory clock change scripts as the driver hands them to the PMU:",
           " * each command is (nwords << 16 | opcode) followed by its arguments. */",
           f"#ifndef {guard}", f"#define {guard}"]
    for (src, dst), words in changes.items():
        start = "the clocks the VBIOS leaves" if src == "boot" else f"{src} MHz"
        out += ["", f"/* {start} to {dst} MHz */", c_array(f"{prefix}_{src}_{dst}", words)]
    out.append("#endif")
    print("\n".join(out))


def main():
    args = sys.argv[1:]
    mode, prefix, mhz, rest = "text", None, {}, []
    i = 0
    while i < len(args):
        if args[i] == "--c":
            mode = "c"
        elif args[i] == "--header":
            mode, prefix = "header", args[i + 1]
            i += 1
        elif args[i] == "--mhz":
            reported, name = args[i + 1].split("=")
            mhz[reported] = name
            i += 1
        else:
            rest.append(args[i])
        i += 1
    path = rest[0]
    bar0 = rest[1] if len(rest) > 1 else "3"
    evs = events(path, bar0)

    if mode == "header":
        header(evs, prefix, mhz)
        return
    mark, count = "start", 0
    for kind, data in evs:
        if kind == "mark":
            mark, count = data, 0
            if mode == "text":
                print(f"== {mark}")
        elif mode == "text":
            print(f"  script ({len(data)} words)")
            print("\n".join(decode(data)))
        else:
            count += 1
            print(f"/* after \"{mark}\", script {count} */")
            print(c_array(f"script_{''.join(c if c.isalnum() else '_' for c in mark)}_{count}", data))


if __name__ == "__main__":
    main()
