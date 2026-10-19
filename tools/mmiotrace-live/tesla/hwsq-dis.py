#!/usr/bin/env python3
"""hwsq-dis.py <trace>

Disassembles the HWSQ scripts a Tesla driver runs in an mmiotrace: the bytes it
writes to the script memory at 0x1400, each time it starts the sequencer with
0x130c. A script is a byte stream:

  0x00-0x1f  wait (op & 3) << 2 * (op >> 2) microseconds
  0x40 a16   write the data register to the address, low half replaced
  0xe0 a32   write the data register to the address
  0x42 d16   set the low half of the data register
  0xe2 d32   set the data register
  0x5f f v   wait until flag f reads v
  0x80|f     clear flag f; 0xa0|f sets it
  0x7f       exit

BAR0 is the trace's MAP of length 0x1000000, as in ../README.md."""
import sys


def dis(code):
    out, i, addr, data = [], 0, 0, 0
    while i < len(code):
        op = code[i]
        if op == 0x7f:
            out.append("exit")
            break
        if op < 0x20:
            out.append(f"wait {(op & 3) << (2 * (op >> 2))} us")
            i += 1
        elif op == 0x42:
            data = (data & 0xffff0000) | int.from_bytes(code[i + 1:i + 3], "little")
            i += 3
        elif op == 0xe2:
            data = int.from_bytes(code[i + 1:i + 5], "little")
            i += 5
        elif op == 0x40:
            addr = (addr & 0xffff0000) | int.from_bytes(code[i + 1:i + 3], "little")
            out.append(f"wr {addr:06x} <- {data:08x}")
            i += 3
        elif op == 0xe0:
            addr = int.from_bytes(code[i + 1:i + 5], "little")
            out.append(f"wr {addr:06x} <- {data:08x}")
            i += 5
        elif op == 0x5f:
            out.append(f"wait flag {code[i + 1]} == {code[i + 2]}")
            i += 3
        elif op & 0x80:
            out.append(f"flag {op & 0x1f} {'set' if op & 0x20 else 'clear'}")
            i += 1
        else:
            out.append(f"?? {op:02x}")
            i += 1
    return out


def main():
    base, words = None, {}
    with open(sys.argv[1], errors="replace") as f:
        for line in f:
            fld = line.split()
            if fld and fld[0] == "MAP" and int(fld[5], 16) == 0x1000000:
                base = int(fld[3], 16)
                break
    if base is None:
        sys.exit("hwsq-dis.py: no 16 MiB BAR0 mapping in the trace")
    with open(sys.argv[1], errors="replace") as f:
        for line in f:
            fld = line.split()
            if fld and fld[0] == "W":
                off = int(fld[4], 16) - base
                if 0x1400 <= off < 0x1600:
                    words[off] = int(fld[5], 16)
                elif off == 0x130c:
                    code = b"".join(words[k].to_bytes(4, "little") for k in sorted(words))
                    print(f"== started at {fld[2]}")
                    for s in dis(code):
                        print("  " + s)


main()
