#!/usr/bin/env python3
"""analog_sim.py: what the dome looks like on a REAL Vectrex (vecx can't show it).

Replays the gen_dome.py view data the way src/dome_draw.s drives the VIA,
through a model of the analog effects measured on consoles by the UVMC2 SDK
(tullulah/uvmc2-sdk vectrex-draw/src/ramp.rs, uvm2-sdk/uvm2_draw.c):
  - the ramp runs T1 + tail cycles (tail ~2.5, console-dependent);
  - the Y sample-and-hold charges toward the DAC with tau ~2.7 cycles for as
    long as the mux is on (`hold` cycles), so big Y jumps can fall short;
  - an optional zero-reference offset adds a constant velocity to every ramp.
It reproduced the 2026-10-06 hardware photo (polylines not meeting) and
predicted the fix (chunk starts at 128 + 3*tail, ~12-cycle Y hold).

  python3 tools/analog_sim.py out.png [--step S] [--tail 2.5] [--pos 136]
                              [--hold 12] [--offset 0]
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_dome as g  # noqa: E402


def simulate(chunks, line_t1, pos, tail, tau, hold, move_hold, off, mirror):
    """Lit segments in nominal DAC units (dac * t / 128)."""
    segs = []
    ysh = 0.0
    a = 1 - math.exp(-hold / tau) if tau > 0 else 1.0
    am = 1 - math.exp(-move_hold / tau) if tau > 0 else 1.0
    sx = -1 if mirror else 1
    for y0, x0, entries in chunks:
        x = y = 0.0                                   # Reset0Ref: back to the centre
        ysh += (y0 - ysh) * am                        # BIOS Moveto_d (long hold)
        t = pos + tail
        x += (sx * x0 + off) * t / 128
        y += (ysh + off) * t / 128
        for is_line, dy, dx in entries:
            ysh += (dy - ysh) * a
            t = line_t1 + tail
            nx = x + (sx * dx + off) * t / 128
            ny = y + (ysh + off) * t / 128
            if is_line:
                segs.append(((x, y), (nx, ny)))
            x, y = nx, ny
    return segs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--step", type=int, default=12)
    ap.add_argument("--tail", type=float, default=g.TAIL_DEFAULT, help="ramp tail, cycles")
    ap.add_argument("--pos", type=int, help="chunk-start scale (default: DOME_POS_DEFAULT)")
    ap.add_argument("--hold", type=float, default=12, help="Y mux window per entry, cycles")
    ap.add_argument("--tau", type=float, default=2.7, help="Y sample-and-hold time constant")
    ap.add_argument("--offset", type=float, default=0.0, help="zero-reference offset, DAC units")
    args = ap.parse_args()

    pts, edges, faces = g.build_mesh()
    mul = 4
    st = args.step % g.VIEWS
    mirror = st >= g.STORED
    chunks = g.make_views(pts, edges, faces, mul, [g.VIEWS - st if mirror else st])[0][0]
    pos = args.pos or round(g.POS_SCALE + (mul - 1) * g.TAIL_DEFAULT)
    segs = simulate(chunks, g.POS_SCALE // mul, pos, args.tail, args.tau, args.hold, 19,
                    args.offset, mirror)
    g.render(args.out, segs)
    print(f"step {args.step}: tail {args.tail}, chunk-start scale {pos}, Y hold {args.hold} -> {args.out}")


if __name__ == "__main__":
    main()
