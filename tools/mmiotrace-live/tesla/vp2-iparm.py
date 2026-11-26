#!/usr/bin/env python3
"""vp2-iparm.py DEMMT_TXT BUF: the BSP parameter blocks (nouveau's struct iparm,
0x530 bytes) the CPU wrote into buffer BUF of a demmt text dump, one per
picture, split where offset 0 is written again; prints the fields nouveau
knows by name, plus every other nonzero dword, for each picture."""
import re, sys

NAMES = {0x000: "chroma_format_idc", 0x128: "log2_max_frame_num_minus4", 0x12c: "poc_type",
         0x130: "log2_max_poc_lsb_minus4", 0x134: "delta_poc_always_zero", 0x138: "num_ref_frames",
         0x13c: "width_mbs-1", 0x140: "height_mapunits-1", 0x144: "frame_mbs_only",
         0x148: "mbaff", 0x14c: "direct_8x8_inference"}
P = 0x150
for off, n in {0x00: "entropy", 0x04: "pic_order_present", 0x08: "slice_groups-1", 0x0c: "slice_group_map",
               0x70: "u70", 0x74: "u74", 0x78: "u78", 0x7c: "l0_active-1", 0x80: "l1_active-1",
               0x84: "weighted_pred", 0x88: "weighted_bipred_idc", 0x8c: "qp-26", 0x90: "chroma_qp_off",
               0x94: "deblock_present", 0x98: "constrained_intra", 0x9c: "redundant_pic_cnt",
               0xa0: "transform_8x8", 0x1c8: "second_chroma_qp", 0x1cc: "u1cc", 0x1d0: "curr_poc",
               0x1d4: "foc0", 0x1d8: "foc1", 0x1dc: "curr_mvidx"}.items():
    NAMES[P + off] = n
R = P + 0x1e0
for i in range(16):
    for off, n in {0x00: "u00", 0x04: "field_is_ref", 0x08: "lt|nonex|u0a|u0b", 0x0c: "frame_idx",
                   0x10: "foc0", 0x14: "foc1", 0x18: "mvidx", 0x1c: "fpf|u1d|u1e|u1f"}.items():
        NAMES[R + i * 0x20 + off] = f"ref{i}.{n}"

buf = sys.argv[2]
pat = re.compile(rf"^w {buf}:0x([0-9a-f]+), 0x([0-9a-f]+)")
pics, cur = [], {}
for line in open(sys.argv[1]):
    m = pat.match(line)
    if not m:
        continue
    off, val = int(m.group(1), 16), int(m.group(2), 16)
    if off >= 0x530:
        continue
    if off == 0 and cur:
        pics.append(cur)
        cur = {}
    cur[off] = val
if cur:
    pics.append(cur)
for n, p in enumerate(pics):
    fields = [f"{NAMES.get(o, hex(o))}={v:#x}" for o, v in sorted(p.items())
              if v or o in (P + 0x1dc, P + 0x1cc)]
    print(f"pic {n}: " + " ".join(fields))
