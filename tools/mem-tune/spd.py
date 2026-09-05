#!/usr/bin/env python3
"""Read every memory module's SPD chip and compare the modules field by field.

The point is not to pretty-print one module -- decode-dimms does that, where it
is installed. The point is the comparison. When modules from different kits or
different production runs share a machine, the controller has to serve all of
them, so it falls back to the loosest value any one of them asks for. That can
quietly slow down the modules that were already there, and nothing in the
booted system reports it.

This prints every module side by side and says plainly whether they agree.

What it can and cannot tell you:

  It reads what each module *advertises*. The frequency and voltage the
  controller actually trained to are a separate question -- read those from
  dmidecode's "Configured Memory Speed" and "Configured Voltage".

  The timings the controller actually applied are a third question again, and
  no Linux interface exposes them on most platforms: command rate, gear-down
  and the secondary timings are visible only in firmware setup. So if latency
  changes after adding modules while the SPD table shows no disagreement, the
  cause is the extra electrical load of more modules per channel, not one
  module dragging the others down.

Needs root (the SPD nodes are readable only by root) and a driver bound to the
SPD chips -- ee1004 for DDR4, spd5118 for DDR5. If nothing is found, load the
driver and make sure the SMBus controller module is present.

DDR4 only: DDR5 moved the fields this parses to different offsets.
"""
import glob
import sys

# JEDEC JEP106 manufacturer identifiers, as (bank, code). Only the ones likely
# to appear on a memory module are listed; anything else prints as raw bytes.
JEDEC = {
    (1, 0x2C): "Micron",   (1, 0x2D): "SK Hynix", (1, 0x4E): "Samsung",
    (1, 0x7E): "Elpida",   (1, 0x0B): "Nanya",    (1, 0x3E): "Winbond",
    (1, 0x51): "Qimonda",  (1, 0x59): "ESMT",     (2, 0x18): "Kingston",
    (3, 0x25): "Kingmax",  (6, 0x04): "CXMT",
}

DDR4 = 0x0C
DEVICE_TYPES = {0x0B: "DDR3", 0x0C: "DDR4", 0x11: "DDR5", 0x12: "DDR5"}


def manufacturer(spd, off):
    """Decode a JEP106 id pair: continuation count, then code. Both carry an
    odd-parity bit in the top position, which is not part of the value."""
    bank = (spd[off] & 0x7F) + 1
    code = spd[off + 1] & 0x7F
    raw = "%02X-%02X" % (spd[off], spd[off + 1])
    name = JEDEC.get((bank, code))
    return "%s [%s]" % (name, raw) if name else raw


def decode(path):
    with open(path, "rb") as fh:
        d = fh.read()
    if len(d) < 512:
        return None, "SPD image too short (%d bytes)" % len(d)
    if d[2] != DDR4:
        return None, "not DDR4 (device type 0x%02x, %s)" % (
            d[2], DEVICE_TYPES.get(d[2], "unknown"))

    mtb = 0.125                       # medium timebase, nanoseconds
    signed = lambda b: b - 256 if b > 127 else b   # fine timebase correction

    tck = d[18] * mtb + signed(d[125]) * 0.001
    if tck <= 0:
        return None, "implausible clock period in SPD"
    taa = d[24] * mtb + signed(d[123]) * 0.001
    trcd = d[25] * mtb + signed(d[122]) * 0.001
    trp = d[26] * mtb + signed(d[121]) * 0.001
    tras = (((d[27] & 0x0F) << 8) | d[28]) * mtb
    trc = ((((d[27] & 0xF0) >> 4) << 8) | d[29]) * mtb + signed(d[120]) * 0.001
    trfc = (d[30] | (d[31] << 8)) * mtb
    clk = lambda t: round(t / tck)

    return {
        "part": d[329:349].decode("ascii", "replace").strip(),
        "module_mfr": manufacturer(d, 320),
        "dram_mfr": manufacturer(d, 350),
        "made": "%02x/%02x" % (d[324], d[323]),      # week/year, BCD
        "rev": "0x%02x" % d[349],
        "speed": "%d MT/s" % round(2000.0 / tck),
        "cl": "CL%d-%d-%d-%d" % (clk(taa), clk(trcd), clk(trp), clk(tras)),
        "tRC": clk(trc),
        "tRFC_ns": round(trfc),
        "tRFC_clk": clk(trfc),
        "xmp": "yes" if d[384] == 0x0C and d[385] == 0x4A else "no",
        "serial": d[325:329].hex().upper(),
    }, None


def main():
    paths = sorted(glob.glob("/sys/bus/i2c/devices/*/eeprom"))
    if not paths:
        sys.exit("no SPD chips exposed. Bind a driver (ee1004 for DDR4) and "
                 "check that the SMBus controller module is loaded.")

    modules, skipped = [], []
    for path in paths:
        try:
            mod, why = decode(path)
        except PermissionError:
            sys.exit("cannot read %s -- run as root." % path)
        except OSError as exc:
            skipped.append((path, str(exc)))
            continue
        if mod:
            modules.append(mod)
        else:
            skipped.append((path, why))

    for path, why in skipped:
        print("skipped %s: %s" % (path, why))
    if not modules:
        sys.exit("no readable DDR4 modules found.")

    columns = ["part", "module_mfr", "dram_mfr", "made", "rev", "speed", "cl",
               "tRC", "tRFC_ns", "tRFC_clk", "xmp", "serial"]
    width = max(len(c) for c in columns) + 2
    print("\n%d module(s)\n" % len(modules))
    for col in columns:
        print(("%-*s" % (width, col)) + "".join("%-22s" % m[col] for m in modules))
    print()

    # Only the fields the controller has to reconcile across modules.
    critical = ["speed", "cl", "tRC", "tRFC_ns"]
    disagree = [c for c in critical if len({str(m[c]) for m in modules}) > 1]
    if disagree:
        print("MISMATCH in: " + ", ".join(disagree))
        print("-> the controller falls back to the loosest value across all")
        print("   modules, so the faster ones are held back by the slowest.")
    else:
        print("All modules advertise identical timings.")
        print("-> nothing is holding anything else back.")

    if len({m["dram_mfr"] for m in modules}) > 1:
        print("Note: the modules do not all use the same memory chips. This is")
        print("      harmless at rated speed with timings left automatic; it")
        print("      matters only if timings are tightened by hand, where the")
        print("      weakest chip sets the limit.")


if __name__ == "__main__":
    main()
