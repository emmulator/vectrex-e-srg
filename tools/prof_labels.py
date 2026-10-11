#!/usr/bin/env python3
"""prof_labels.py: cycles per game loop by label, from a VXPROF profile.

  make -B GCC_FLAGS=... KEEP_WORK=1            # keeps the .rst listings
  VXPROF=prof.txt tests/vxhost <vecxstat core> build/e-srg.bin --frames N [...]
  python3 tools/prof_labels.py prof.txt [top]

The vecxstat core (template tools/vecxstat) writes cycles per PC. Each PC is
charged to the nearest label before it in build/.gcc6809-work/*.rst (C
functions included, static ones too); BIOS addresses ($E000+) are grouped as
BIOS, the Wait_Recal wait loop ($F192-$F1AF) as idle.
"""
import glob
import re
import sys

prof = {int(a, 16): int(c) for a, c in (l.split() for l in open(sys.argv[1]))}
top = int(sys.argv[2]) if len(sys.argv) > 2 else 25
loops = sum(prof.values()) / 30000
labels = []
for f in glob.glob("build/.gcc6809-work/*.rst"):
    mod = f.split("/")[-1][:-4]
    for line in open(f, errors="ignore"):
        m = re.match(r"\s+([0-9A-F]{4})\s+(?:[0-9A-F]{2} ?)*\s*(?:\[\s*\d+\])?\s*\d+\s+([A-Za-z_.][A-Za-z_0-9.]*):", line)
        if m and not re.match(r"L\d+$|\d+\$", m.group(2)):   # skip gcc/local labels
            labels.append((int(m.group(1), 16), f"{mod}:{m.group(2)}"))
labels.sort()
cost = {}
import bisect
addrs = [a for a, _ in labels]
for pc, c in prof.items():
    if 0xF192 <= pc < 0xF1B0:
        k = "idle (Wait_Recal)"
    elif pc >= 0xE000:
        k = "BIOS"
    else:
        i = bisect.bisect_right(addrs, pc) - 1
        k = labels[i][1] if i >= 0 else "?"
    cost[k] = cost.get(k, 0) + c
for k, c in sorted(cost.items(), key=lambda kv: -kv[1])[:top]:
    print(f"{c / loops:8.0f}  {k}")
