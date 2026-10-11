#!/usr/bin/env python3
"""
gen_dome.py: generate the E-SRG dome (a geodesic hexagon/pentagon cap) as
precomputed, ready-to-draw vector lists for src/dome_draw.s.

Geometry
  A Goldberg polyhedron GP(FREQ,0): the dual of the frequency-FREQ
  icosahedral geodesic sphere, i.e. 12 pentagons and the rest hexagons (a
  "soccer ball" geodesic dome). A pentagon is centred on +Y. The dome keeps
  the whole polygons whose centre is within RIM_DEG of the peak: 63.5 takes
  the ring that ends at the next 5 pentagons (63.4 deg), the most regular
  whole-polygon bottom edge short of a ball shape (corners 62.4..69.6 deg).
  With RIM_DEG = None the sphere is instead cut flat by the plane
  y = cos(CAP_DEG). A fixed perspective camera looks down at it; the dome
  rotates about Y.

Why whole views are precomputed
  Building vector lists at run time cost ~230 cycles per edge even in
  hand-written 6809 asm (~400 in gcc6809 C): 2-4 frames per redraw. But the
  dome only rotates about its axis and the camera is fixed, so:
  - 5-fold symmetry: the picture at rotation step s (STEPS per turn) equals
    the one at s mod VIEWS, VIEWS = STEPS/5;
  - mirror symmetry: the mesh is oriented so x -> -x maps it onto itself, so
    view VIEWS-s is view s mirrored left-right.
  So only views 0..VIEWS/2 are stored; dome_draw.s mirrors the rest by
  negating x. For each stored view the generator projects the points, keeps
  the edges of polygons facing the camera (exact hidden-line removal for a
  convex polyhedron; silhouette edges are polyhedron edges), orders them
  into few polylines (greedy pen-plotter ordering) and encodes them. Every
  visible edge is drawn exactly once.

Data format (dome_views[v], v = 0..DOME_STORED-1)
  chunk*: n, y, x, then n entries
    entry: dy, dx          line (dy is never -128)
           0x80, dy, dx    blank move
  0       end of view
  y, x: chunk start (scale DOME_POS_SCALE, after Reset0Ref and, if
        DOME_ANCHOR_Y, the anchor move: y is relative to it).
  Deltas are pre-multiplied by LINE_MUL and drawn at DOME_LINE_SCALE =
  POS_SCALE/LINE_MUL (same geometry, less beam time per vector).

Enemy missiles: see "enemy missiles" below (missile_data.[ch], missile_cfg.inc
for src/missile_draw.s).

Usage
  python3 tools/gen_dome.py                 # writes src/dome_data.[ch], src/dome_cfg.inc,
                                            #   src/missile_data.[ch], src/missile_cfg.inc
  python3 tools/gen_dome.py --preview out.png [--step S] [--ship N]   # render a view
  --freq N / --rim DEG / --cap DEG override FREQ / RIM_DEG / CAP_DEG (try
  looks without editing; --cap implies a flat cut)
"""
import argparse
import math
import os
from collections import defaultdict

import numpy as np

# ---- tunables ------------------------------------------------------------
FREQ = 5             # pentagon to pentagon = FREQ cell steps; higher = smaller cells
RIM_DEG = 63.5       # keep whole polygons whose centre is within RIM_DEG of the peak
CAP_DEG = 62.0       # only if RIM_DEG is None: polar angle of a flat cut
CAM_ELEV_DEG = 38.0  # camera elevation, seen from the sphere center
CAM_DIST = 2.6       # camera distance from the sphere center (sphere radius = 1)
LOOK_Y = 0.55        # camera looks at (0, LOOK_Y, 0)
X_HALF = 116         # DAC units: the dome spans x in [-X_HALF, X_HALF] ...
Y_BOTTOM = -236      # ... and its lowest point sits at Y_BOTTOM, or it is centred
                     # vertically if None (leave room for chunk starts drawn at
                     # POS_DEFAULT instead of POS_SCALE)
LINE_MUL = 4         # strokes at POS_SCALE/LINE_MUL = 0x10: ~5.9k cycles free while moving.
                     # 2 (0x20) looks a bit cleaner on hardware but leaves ~2.3k (2026-10-06);
                     # None = cheapest of 1, 2, 4, 8
STEPS = 240          # rotation steps per turn (multiple of 10)
CHUNK = 24           # max entries per absolute re-anchor (integrator drift)
POS_SCALE = 0x40     # nominal scale of a DAC unit: strokes are drawn at POS_SCALE/LINE_MUL.
                     # 0x40: the dome spans half the screen width (room for things
                     # approaching it) at the same DAC precision as 0x80 at full width
                     # (halving the coordinates at 0x80 instead looked coarse and choppy).
# Real consoles keep ramping ~2.5 cycles after T1 expires (the "tail", measured
# on hardware by the UVMC2 SDK: tullulah/uvmc2-sdk vectrex-draw/src/ramp.rs).
# A stroke at scale L really travels dac*(L+tail), so a chain of short strokes
# comes out longer than the absolute move to the chunk start and the
# polylines stop meeting (seen on a real Vectrex 2026-10-06; vecx has no
# tail). dome_draw.s therefore draws the chunk starts at dome_pos_scale, which
# should be POS_SCALE + (LINE_MUL-1)*tail: then POS+tail = LINE_MUL*(L+tail).
# The game lets the player trim it (button 1 + stick); POS_SCALE suits vecx.
TAIL_DEFAULT = 2.5      # a typical console (UVMC2 SDK's measurements): the default build
TAIL_MINE = 10 / 3      # one particular console (CAL 138 at POS_SCALE 0x80): -DDOME_MINE; set your own
# cycle model (dome_draw.s, measured): ~48 cycles + scale per entry; a chunk start
# (Reset0Ref + Moveto_d at POS_SCALE) ~ 80 + POS_SCALE
ENTRY_OVERHEAD = 48
CHUNK_OVERHEAD = 80 + POS_SCALE
# Anchor: if the picture doesn't fit +-127 DAC units (e.g. a dome low on the
# screen at POS_SCALE 0x40), each chunk first makes a fixed blank move of
# ANCHOR_DAC at ANCHOR_SCALE (the smallest scale that reaches; it moves
# ANCHOR_Y units) and stores its start relative to that. Every chunk makes the
# same move, so any analog error in it (ramp tail) shifts the whole picture,
# not chunks against each other. Set in main().
ANCHOR_Y, ANCHOR_DAC, ANCHOR_SCALE = 0, 0, 0
VIEWS = STEPS // 5
STORED = VIEWS // 2 + 1

# ---- the ship -------------------------------------------------------------
# A 3-sided pyramid (an arrowhead) standing on the dome's FRONT meridian (the
# one facing the camera), nose toward the peak. Left/right spins the dome
# under it, so the ship itself only ever changes latitude: SHIP_STEPS views
# from the peak (index 0) down to SHIP_MAX_DEG, drawn by ship_draw in
# dome_draw.s. The front meridian always faces the camera, so the ship can
# never reach the hidden side.
SHIP_STEPS = 48               # latitude views; the lowest is the lowest cell centre
SHIP_MAX_DEG = None           # set from the cells (see make_cells)
CELL_RIM_MARGIN_DEG = 3.0     # flat cut only: a cell is walkable if whole and its centre this far above the cut
STICK_DIRS = 32               # stick directions (11.25 deg each), 0 = right, 8 = up
STICK_DEAD = 40               # analog stick dead zone (of 127)
MOVE_FRAMES = 16              # a move (to a neighbouring cell) takes this many frames
SHIP_LEN = 0.15              # nose to tail, in sphere radii
SHIP_WIDTH = 0.12            # across the tail
SHIP_HEIGHT = 0.09           # apex above the surface


def rot_to(a, b):
    """rotation matrix taking unit vector a onto unit vector b."""
    v, c = np.cross(a, b), a @ b
    K = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + K + K @ K / (1 + c)


def build_mesh():
    """Goldberg cap: points [n,3] at rotation 0, edges (index pairs), faces (index polygons)."""
    t = (1 + 5 ** 0.5) / 2
    ico = np.array([[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
                    [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]], float)
    ico /= np.linalg.norm(ico, axis=1, keepdims=True)
    ifaces = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4),
              (11, 10, 2), (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8),
              (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    # vertex 0 (a pentagon centre of the dual) onto +Y, then its neighbour 1
    # onto the x = 0 plane: that plane is then a mirror plane of the mesh
    ico = ico @ rot_to(ico[0], np.array([0.0, 1.0, 0.0])).T
    az = math.atan2(ico[1][0], ico[1][2])
    ry = np.array([[math.cos(az), 0, -math.sin(az)], [0, 1, 0], [math.sin(az), 0, math.cos(az)]])
    ico = ico @ ry.T
    assert abs(ico[1][0]) < 1e-9

    gpts, gid, tris = [], {}, []           # geodesic sphere (primal)

    def gp(p):
        p = p / np.linalg.norm(p)
        key = tuple(np.round(p, 6))
        if key not in gid:
            gid[key] = len(gpts)
            gpts.append(p)
        return gid[key]
    n = FREQ
    for ia, ib, ic in ifaces:
        A, B, C = ico[ia], ico[ib], ico[ic]
        P = {(i, j): gp(A + (B - A) * i / n + (C - A) * j / n)
             for i in range(n + 1) for j in range(n + 1 - i)}
        for i in range(n):
            for j in range(n - i):
                tris.append((P[i, j], P[i + 1, j], P[i, j + 1]))
                if i + j < n - 1:
                    tris.append((P[i + 1, j], P[i + 1, j + 1], P[i, j + 1]))
    gpts = np.array(gpts)

    # dual: a point per triangle (centroid pushed to the sphere), a face per primal vertex
    dpts = np.array([gpts[list(tr)].mean(axis=0) for tr in tris])
    dpts /= np.linalg.norm(dpts, axis=1, keepdims=True)
    around = defaultdict(list)
    for ti, tr in enumerate(tris):
        for v in tr:
            around[v].append(ti)
    y0 = math.cos(math.radians(CAP_DEG))
    pts, pid = [], {}

    def pt(p):
        key = tuple(np.round(p, 6))
        if key not in pid:
            pid[key] = len(pts)
            pts.append(p)
        return pid[key]
    faces = []
    for v, tlist in around.items():
        c = gpts[v]
        e1 = np.cross(c, [0.3, 0.5, 0.7])
        e1 /= np.linalg.norm(e1)
        e2 = np.cross(c, e1)
        poly = [dpts[ti] for ti in sorted(tlist, key=lambda ti: math.atan2(dpts[ti] @ e2, dpts[ti] @ e1))]
        if RIM_DEG is not None:             # whole polygons only
            m = np.mean(poly, axis=0)
            if math.degrees(math.acos(min(1.0, m[1] / np.linalg.norm(m)))) <= RIM_DEG + 0.01:
                faces.append([pt(p) for p in poly])
            continue
        out = []                            # clip to y >= y0 (Sutherland-Hodgman)
        for k in range(len(poly)):
            P, Q = poly[k], poly[(k + 1) % len(poly)]
            if P[1] >= y0:
                out.append(P)
            if (P[1] >= y0) != (Q[1] >= y0):
                lo, hi = (P, Q) if tuple(P) < tuple(Q) else (Q, P)   # same point for both faces
                out.append(lo + (hi - lo) * (y0 - lo[1]) / (hi[1] - lo[1]))
        if len(out) >= 3:
            ids = [pt(p) for p in out]
            faces.append([i for k, i in enumerate(ids) if i != ids[k - 1]])
    edges = set()
    for f in faces:
        for k in range(len(f)):
            u, w = f[k], f[(k + 1) % len(f)]
            edges.add((min(u, w), max(u, w)))
    return np.array(pts), sorted(edges), faces


def camera():
    e = math.radians(CAM_ELEV_DEG)
    pos = np.array([0.0, CAM_DIST * math.sin(e), CAM_DIST * math.cos(e)])
    fwd = np.array([0.0, LOOK_Y, 0.0]) - pos
    fwd /= np.linalg.norm(fwd)
    right = np.cross(fwd, [0, 1, 0])
    right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    return pos, fwd, right, up


def project(pts, step):
    """raw (unscaled) screen coords [n,2] and rotated world points [n,3]."""
    pos, fwd, right, up = camera()
    a = 2 * math.pi * step / STEPS
    rot = np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])
    world = pts @ rot.T
    d = world - pos
    z = d @ fwd
    return np.column_stack([d @ right / z, d @ up / z]), world


def visible_edges(edges, faces, world):
    """Exact hidden-line removal for a convex polyhedron: an edge is visible
    iff at least one face using it faces the camera."""
    pos = camera()[0]
    front = set()
    for f in faces:
        P = world[list(f)]
        n = sum(np.cross(P[k], P[(k + 1) % len(P)]) for k in range(len(P)))   # Newell normal
        ctr = P.mean(axis=0)
        if n @ ctr < 0:                     # orient outward (the cap is convex around the origin)
            n = -n
        if n @ (pos - ctr) > 0:
            for k in range(len(f)):
                u, v = f[k], f[(k + 1) % len(f)]
                front.add((min(u, v), max(u, v)))
    return [e for e in edges if e in front]


def screen_fit(pts):
    """scale/offset mapping raw coords to screen units, from all views."""
    allraw = np.vstack([project(pts, s)[0] for s in range(VIEWS)])
    s = X_HALF / np.abs(allraw[:, 0]).max()
    if Y_BOTTOM is None:
        return s, -(allraw[:, 1].min() + allraw[:, 1].max()) / 2 * s
    return s, Y_BOTTOM - allraw[:, 1].min() * s


def order_edges(edges, scr):
    """Greedy pen-plotter ordering: follow unused edges; when stuck, jump to
    the nearest vertex that still has unused edges (preferring odd ones).
    Returns a list of (kind, vertex) with kind 'start', 'line' or 'move'."""
    adj = defaultdict(set)
    for a, b in edges:
        adj[a].add(b)
        adj[b].add(a)
    ops = []
    cur = None
    while any(adj.values()):
        live = [v for v in adj if adj[v]]
        odd = [v for v in live if len(adj[v]) % 2] or live
        if cur is None:
            nxt = min(odd, key=lambda v: (scr[v][1], scr[v][0]))   # lowest point first
            ops.append(("start", nxt))
        else:
            nxt = min(odd, key=lambda v: abs(scr[v] - scr[cur]).max())
            ops.append(("move", nxt))
        cur = nxt
        while adj[cur]:
            # prefer a neighbour where the trail can go on
            w = max(adj[cur], key=lambda w: (len(adj[w]) - 1) % 2 == 1)
            adj[cur].discard(w)
            adj[w].discard(cur)
            ops.append(("line", w))
            cur = w
    return ops


def split(d, lim):
    """split a delta in halves until both components fit in +-lim."""
    if abs(d[0]) <= lim and abs(d[1]) <= lim:
        return [d]
    h = (int(d[0] / 2), int(d[1] / 2))
    return split(h, lim) + split((d[0] - h[0], d[1] - h[1]), lim)


def build_view(ops, scr, mul):
    """ops -> chunks [(y, x, [(is_line, dy, dx), ...]), ...] with scaled deltas."""
    lim = 127 // mul
    chunks = []
    cur_pos = None
    entries = None

    def new_chunk(p):
        nonlocal entries
        entries = []
        y = round(p[1] - ANCHOR_Y)
        assert -128 <= y <= 127 and -128 <= int(p[0]) <= 127, "chunk start out of DAC range"
        chunks.append((y, int(p[0]), entries))

    for kind, v in ops:
        p = scr[v]
        if kind == "start":
            new_chunk(p)
        else:
            pieces = split((int(p[1] - cur_pos[1]), int(p[0] - cur_pos[0])), lim)
            if kind == "move" and len(pieces) * (ENTRY_OVERHEAD + POS_SCALE // mul) > CHUNK_OVERHEAD:
                new_chunk(p)                # a long blank move: cheaper as a fresh start
            elif len(entries) + len(pieces) > CHUNK:
                new_chunk(p if kind == "move" else cur_pos)
                if kind == "line":
                    entries.extend((True, dy * mul, dx * mul) for dy, dx in pieces)
            else:
                entries.extend((kind == "line", dy * mul, dx * mul) for dy, dx in pieces)
        cur_pos = p
    return chunks


def view_cost(chunks, mul):
    n = sum(len(e) for _, _, e in chunks)
    anchor = 40 + ANCHOR_SCALE
    return len(chunks) * (CHUNK_OVERHEAD + anchor) + n * (ENTRY_OVERHEAD + POS_SCALE // mul), n


def view_segments(chunks, mul, mirror=False):
    """the lit segments a view draws (as the run time would), for checks/preview."""
    out = []
    sx = -1 if mirror else 1
    for y, x, entries in chunks:
        y, x = float(y + ANCHOR_Y), float(x * sx)
        for is_line, dy, dx in entries:
            ny, nx = y + dy / mul, x + sx * dx / mul
            if is_line:
                out.append(((x, y), (nx, ny)))
            y, x = ny, nx
    return out


def make_views(pts, edges, faces, mul, steps):
    s, oy = screen_fit(pts)
    views = []
    for step in steps:
        raw, world = project(pts, step)
        scr = np.round(np.column_stack([raw[:, 0] * s, raw[:, 1] * s + oy])).astype(int)
        vedges = visible_edges(edges, faces, world)
        views.append((build_view(order_edges(vedges, scr), scr, mul), len(vedges)))
    return views


def check_mirror(pts, edges, faces, mul):
    """view VIEWS-s must equal view s mirrored (what dome_draw.s relies on):
    every mirrored segment of s has a segment of VIEWS-s within 1 unit."""
    def near(e, f):
        return all(abs(a - b) <= 1 for p, q in zip(e, f) for a, b in zip(p, q))

    def norm(seg):
        return tuple(sorted(seg))
    for s in (1, 5, 11, STORED - 1):
        a = [norm(e) for e in view_segments(make_views(pts, edges, faces, mul, [s])[0][0], mul, mirror=True)]
        b = [norm(e) for e in view_segments(make_views(pts, edges, faces, mul, [VIEWS - s])[0][0], mul)]
        miss = [e for e in a if not any(near(e, f) for f in b)]
        assert not miss and len(a) == len(b), f"mirror symmetry broken at step {s}: {miss[:3]}"


def ship_model(theta):
    """Pyramid on the front meridian at polar angle theta: points [4,3], faces."""
    p = np.array([0.0, math.cos(theta), math.sin(theta)])   # surface point; normal = p
    fwd = np.array([0.0, math.sin(theta), -math.cos(theta)])  # tangent toward the peak
    side = np.cross(p, fwd)
    nose = p + fwd * (SHIP_LEN * 0.6)
    tl = p - fwd * (SHIP_LEN * 0.4) + side * (SHIP_WIDTH / 2)
    tr = p - fwd * (SHIP_LEN * 0.4) - side * (SHIP_WIDTH / 2)
    apex = p - fwd * (SHIP_LEN * 0.1) + p * SHIP_HEIGHT
    pts = np.array([nose, tl, tr, apex])
    faces = [[0, 1, 2], [3, 0, 1], [3, 1, 2], [3, 2, 0]]      # base first
    return pts, faces


def ship_visible_edges(pts, faces):
    """Edges of the faces that face the camera (a pyramid is convex)."""
    pos = camera()[0]
    ctr = pts.mean(axis=0)
    out = set()
    for f in faces:
        P = pts[f]
        n = np.cross(P[1] - P[0], P[2] - P[0])
        fc = P.mean(axis=0)
        if n @ (fc - ctr) < 0:
            n = -n
        if n @ (pos - fc) > 0:
            for k in range(len(f)):
                u, v = f[k], f[(k + 1) % len(f)]
                out.add((min(u, v), max(u, v)))
    return sorted(out)


def make_cells(pts, faces):
    """Walkable cells (every polygon; with a flat cut, the whole ones whose
    centre is clear of the cut) and the
    movement tables. Cell 0 is the peak pentagon. A cell's centre is the
    normalised mean of its corners. Returns a dict of tables for dome_data."""
    global SHIP_MAX_DEG
    y0 = math.cos(math.radians(CAP_DEG))
    cells = []
    for f in faces:
        P = pts[list(f)]
        c = P.mean(axis=0)
        c /= np.linalg.norm(c)
        if RIM_DEG is None and (len(f) < 5 or np.any(np.abs(P[:, 1] - y0) < 1e-6)
                                or math.degrees(math.acos(min(1.0, c[1]))) > CAP_DEG - CELL_RIM_MARGIN_DEG):
            continue                                             # clipped by / too near the cut
        cells.append((f, c))
    cells.sort(key=lambda fc: -fc[1][1])                         # peak first
    assert len(cells[0][0]) == 5 and cells[0][1][1] > 0.999, "cell 0 must be the peak pentagon"
    centres = [c for _, c in cells]
    theta = [math.acos(min(1.0, c[1])) for c in centres]
    phi = [math.atan2(c[0], c[2]) for c in centres]
    SHIP_MAX_DEG = math.degrees(max(theta))
    lat = [round(t / max(theta) * (SHIP_STEPS - 1)) for t in theta]
    step = [round(-p * STEPS / (2 * math.pi)) % STEPS for p in phi]
    step[0] = 0
    # neighbours: cells sharing an edge
    edge_cells = defaultdict(list)
    for i, (f, _) in enumerate(cells):
        for k in range(len(f)):
            u, v = f[k], f[(k + 1) % len(f)]
            edge_cells[(min(u, v), max(u, v))].append(i)
    nbrs = defaultdict(set)
    for cs in edge_cells.values():
        if len(cs) == 2:
            nbrs[cs[0]].add(cs[1])
            nbrs[cs[1]].add(cs[0])
    pos, fwd, right, up = camera()

    def screen_dir(a, b, rot):
        """screen angle of the move a -> b with the dome turned by `rot` radians."""
        R = np.array([[math.cos(rot), 0, math.sin(rot)], [0, 1, 0], [-math.sin(rot), 0, math.cos(rot)]])
        q = []
        for c in (centres[a], centres[b]):
            d = R @ c - pos
            z = d @ fwd
            q.append(np.array([d @ right / z, d @ up / z]))
        v = q[1] - q[0]
        return math.atan2(v[1], v[0])
    # per cell, the best neighbour for each stick direction (within 45 deg)
    nbr_tab = []
    for i in range(len(cells)):
        row = []
        dirs = [(screen_dir(i, j, -phi[i]), j) for j in nbrs[i]] if i else []
        for d in range(STICK_DIRS):
            want = 2 * math.pi * d / STICK_DIRS
            best = min(dirs, key=lambda aj: abs((aj[0] - want + math.pi) % (2 * math.pi) - math.pi),
                       default=None)
            ok = best and abs((best[0] - want + math.pi) % (2 * math.pi) - math.pi) <= math.radians(45)
            row.append(best[1] if ok else 255)
        nbr_tab.append(row)
    # stored instead: per cell its neighbours and their screen directions (in
    # 1/256 turn); the game picks the nearest to the stick (cell_toward in
    # e-srg.c, modelled here) less than 45 degrees (32/256) off
    adj = []
    for i in range(len(cells)):
        dirs = [(round(screen_dir(i, j, -phi[i]) / (2 * math.pi) * 256) % 256, j)
                for j in sorted(nbrs[i])]          # (the peak's: for the collapse rule only)
        assert len(dirs) <= 6
        adj.append(dirs + [(0, 255)] * (6 - len(dirs)))
    differ = 0
    for i in range(1, len(cells)):
        for d in range(STICK_DIRS):
            best, bd = 255, 32
            for a, j in adj[i]:
                if j == 255:
                    break
                e = (a - d * 8) & 255
                e = 256 - e if e & 128 else e
                if e < bd:
                    best, bd = j, e
            differ += best != nbr_tab[i][d]
            nbr_tab[i][d] = best
    # the peak: "down" goes to the ring cell nearest the front for the current spin
    peak_down = []
    ring = sorted(nbrs[0])
    for st in range(STEPS // 5):
        rot = 2 * math.pi * st / STEPS
        peak_down.append(min(ring, key=lambda j: abs((phi[j] + rot + math.pi) % (2 * math.pi) - math.pi)))
    # analog stick (x, y) -> direction, on a 32x32 grid of the -128..127
    # range; stored for one quadrant (16x16, x, y > 0): the game mirrors it
    def sdir(x, y):
        if math.hypot(x, y) < STICK_DEAD:
            return 255
        return round(math.atan2(y, x) / (2 * math.pi) * STICK_DIRS) % STICK_DIRS
    stick = [sdir(4 + 8 * ax, 4 + 8 * ay) for ay in range(16) for ax in range(16)]
    for gy in range(32):                 # the mirroring must reproduce the full grid
        for gx in range(32):
            ax, ay = (gx - 16, gy - 16) if False else (gx - 16 if gx >= 16 else 15 - gx,
                                                     gy - 16 if gy >= 16 else 15 - gy)
            d = stick[ay * 16 + ax]
            if d != 255:
                if gx < 16:
                    d = (STICK_DIRS // 2 - d) % STICK_DIRS
                if gy < 16:
                    d = (STICK_DIRS - d) % STICK_DIRS
            want = sdir(gx * 8 - 124, gy * 8 - 124)
            assert d == want or (d - want) % STICK_DIRS in (1, STICK_DIRS - 1), (gx, gy, d, want)
    print(f"moves: runtime pick differs from exact angles in {differ} of {(len(cells) - 1) * STICK_DIRS} cases (ties, or right at 45 deg)")
    return dict(n=len(cells), step=step, lat=lat, nbr=nbr_tab, adj=adj, peak_down=peak_down, stick=stick,
                theta=theta, nbrs=nbrs)


def make_ship_views(dome_pts, mul):
    s, oy = screen_fit(dome_pts)          # the dome's mapping, so the ship sits on it
    views = []
    for i in range(SHIP_STEPS):
        theta = math.radians(SHIP_MAX_DEG) * i / (SHIP_STEPS - 1)
        pts, faces = ship_model(theta)
        raw, _ = project(pts, 0)
        scr = np.round(np.column_stack([raw[:, 0] * s, raw[:, 1] * s + oy])).astype(int)
        views.append(build_view(order_edges(ship_visible_edges(pts, faces), scr), scr, mul))
    return views


def write_chunks(f, name, chunks):
    f.write(f"static const unsigned char {name}[] = {{\n")
    for y, x, entries in chunks:
        f.write(f"  {len(entries)}, {y & 255}, {x & 255},\n   ")
        f.write(" ".join((f"{dy & 255},{dx & 255}," if l else f"128,{dy & 255},{dx & 255},")
                         for l, dy, dx in entries))
        f.write("\n")
    f.write("  0\n};\n")


def render(path_png, segs):
    from PIL import Image, ImageDraw
    W, H = 330, 410
    k = 330 / 254.0 * POS_SCALE / 0x7f      # px per unit (measured: x=+-127 @0x7f = screen width)
    img = Image.new("L", (W, H), 0)
    dr = ImageDraw.Draw(img)
    for (x0, y0), (x1, y1) in segs:
        dr.line([(W / 2 + x0 * k, H / 2 - y0 * k), (W / 2 + x1 * k, H / 2 - y1 * k)], fill=220)
    img.save(path_png)


# ---- enemy missiles ----------------------------------------------------------
# A missile flies a straight line through the centre of a cell toward the
# sphere's centre, fixed in the dome's frame: it turns with the dome. Its
# position can't be precomputed (it depends on the rotation, the cell and the
# distance), so missile_draw.s projects it every frame in fixed point; this
# generator makes the tables and checks the integer maths (mis_project_int,
# which missile_draw.s follows step by step) against exact projection. Its shape, a
# tetrahedron dart (tip first), is precomputed per ring of cells and per 7.5
# degrees of azimuth (mirror symmetry halves that) and drawn at a scale that
# follows the perspective.
#
# State per missile (24-bit signed, big-endian, units of 2^-19, so the top 16
# bits are 5.11 fixed point: +-16 at 1/2048):
#   H = r sin(theta)                       horizontal distance from the axis
#   A = (r cos(theta) - py) fy - pz fz     depth, without the azimuth term
#   B = (r cos(theta) - py) uy - pz uz     height on screen, ditto
#   R = r                                  distance from the sphere centre
# All four are linear in r, so a flight is four 24-bit adds per frame. The
# start values are computed back from the exact impact values, so the missile
# lands exactly on the cell centre (R = 1.0) after a whole number of frames.
FRAC = 1 << 19
MIS_LEN = 0.22          # tip to base, in sphere radii
MIS_WIDTH = 0.075       # base corner distance from the axis
MIS_SPEEDS = (0.010, 0.013, 0.017, 0.022)   # sphere radii per frame, by speed index
MIS_SPRITE_PHI = 48     # sprite views per turn (stored: half + 1, mirrored)
MIS_ZMIN = 0.35         # nearer than this (in front of the camera): not drawn
MIS_ZMAX = 7.9
MIS_XLIM = 250          # drawn while |x| <= MIS_XLIM and MIS_YLO <= y <= MIS_YHI
MIS_YLO = -300          # (units at POS_SCALE, screen centre = 0)
MIS_YHI = 300
MIS_R_MAX = 3.0         # start distance for rings whose lines never leave the screen
MIS_SCALE_REF = 0x10    # sprite line scale at depth 2.0
MIS_FLOOR_Y = math.cos(math.radians(66))   # the dome's solid floor (for hiding)
# The player's bullets fly the same kind of radial line outward from the
# ship's cell (so they can only meet missiles aimed at that cell): same state,
# projection and hiding, drawn as a short line along the radius.
BUL_LEN = 0.12          # bullet length (its head starts this far above the cell)
BUL_SIZE = 0.5          # a bullet is the missile's dart turned tip-outward (its
                        # picture drawn with x and y negated) at this size
BUL_SPEED = 0.06        # sphere radii per frame
# Explosion: fragments flying out from where a missile was hit, a precomputed
# 2D animation drawn at the hit's screen position.
EXPL_STEPS = 16         # animation steps (each drawn EXPL_HOLD frames)
EXPL_HOLD = 2
EXPL_PIECES = 6
EXPL_SCALE = 0x20       # drawn at this scale: 1 DAC unit = EXPL_SCALE/POS_SCALE units
# Radar (Elite's 3D scanner): an ellipse for the plane through the sphere's
# centre, seen from the camera's side; each missile is a stick from its spot
# on the plane up to its height, with a dash on top. It turns with the dome
# (front = near side, bottom of the ellipse). radar.s draws it.
# Broken tiles: a flickering crack at the tile's centre (cracks.s). The
# centre's screen position depends only on its ring and its azimuth on screen
# j, so one table covers every tile: crack_pos[ring][j / 4] (x, y), j mirrored
# to 0..120 (x negated beyond), blended linearly between entries; x = -128:
# the centre faces away (hidden; also between a hidden and a shown entry). y is relative to the sphere centre's projection (add mis_oy).
# The crack lies on the tile: crack_look[ring][j / 8] gives its scale and one
# of CRACK_ASPECTS flattenings (vertical or horizontal) of the 4 shapes, from
# the projected size of the tile's surface there (seen edge-on at the back
# rim, sideways at the sides).
CRACK_SCALE = 0x14      # scale where the dome's surface looks largest
CRACK_ASPECTS = (1.0, 0.7, 0.45, 0.25)
CRACK_SHAPES = [        # zig-zags in screen units where the surface looks largest
    [(-7, 2), (-2, -1), (2, 3), (7, -2)],
    [(-5, -5), (-1, 0), (1, -2), (5, 5)],
    [(-6, 4), (-1, 1), (0, -3), (6, -4)],
    [(0, 7), (2, 1), (-2, -2), (1, -7)],
]
# HUD digits (hud.s): vector glyphs on a 4 x 6 grid, each from its lower
# left corner and ending at the next glyph's (advance HUD_ADVANCE), drawn at
# HUD_SCALE with HUD_UNIT DAC units per grid step. BIOS text (raster) cost
# ~3.7k cycles for "DOME 100%"; these cost ~50 per stroke.
HUD_SCALE = 0x10
HUD_UNIT = 15
HUD_ADVANCE = 6
# glyph: list of strokes, each a polyline of grid points (pen up between)
HUD_GLYPHS = {
    "0": [[(0, 0), (4, 0), (4, 6), (0, 6), (0, 0)]],
    "1": [[(4, 0), (4, 6)]],
    "2": [[(0, 6), (4, 6), (4, 3), (0, 3), (0, 0), (4, 0)]],
    "3": [[(0, 0), (4, 0), (4, 6), (0, 6)], [(0, 3), (4, 3)]],
    "4": [[(0, 6), (0, 3), (4, 3)], [(4, 6), (4, 0)]],
    "5": [[(4, 6), (0, 6), (0, 3), (4, 3), (4, 0), (0, 0)]],
    "6": [[(4, 6), (0, 6), (0, 0), (4, 0), (4, 3), (0, 3)]],
    "7": [[(0, 6), (4, 6), (4, 0)]],
    "8": [[(0, 0), (4, 0), (4, 6), (0, 6), (0, 0)], [(0, 3), (4, 3)]],
    "9": [[(0, 0), (4, 0), (4, 6), (0, 6), (0, 3), (4, 3)]],
    "%": [[(0, 0), (4, 6)], [(0, 5), (0, 5)], [(4, 1), (4, 1)]],      # slash and two dots
    "dome": [[(0, 0), (1, 2.5), (3, 3.5), (5, 2.5), (6, 0)]],         # the label: a little dome
    "ship": [[(0, 0), (4, 0), (2, 5), (0, 0)]],                       # a life
}
MIS_LEAD = 1.0          # missiles start this much further out, so the radar shows them first
RADAR_RANGE = 6.0       # sphere radii at the ellipse's edge
RADAR_R = 90            # ellipse x radius, DAC units at RADAR_SCALE
RADAR_FLAT = 0.28       # ellipse y radius / x radius
RADAR_H = 90            # stick height at RADAR_RANGE straight up, DAC units
RADAR_H_POW = 2         # stick height ~ R cos(theta)^POW: 1 = true height; 2 shortens
                        # low-coming missiles' sticks more, so low reads as low
RADAR_SCALE = 0x28      # sticks and dashes (1 DAC = RADAR_SCALE/POS_SCALE units)
RADAR_ESCALE = 0x14     # the ellipse: half the scale, twice the DAC values (cheaper)
RADAR_SEGS = 12         # ellipse segments
RADAR_ROOF = True       # draw the dome as a small roof in the middle
RADAR_CX = -185         # ellipse centre on screen, units at POS_SCALE: bottom left,
RADAR_CY = -205         #   beside the dome


def mis_rings(cells):
    th = sorted({round(t, 6) for t in cells["theta"]})
    ring = [min(range(len(th)), key=lambda k: abs(th[k] - t)) for t in cells["theta"]]
    return th, ring


def mis_consts(pts):
    s, oy = screen_fit(pts)
    pos, fwd, right, up = camera()
    assert abs(right[0] - 1) < 1e-9 and abs(fwd[0]) < 1e-9 and abs(up[0]) < 1e-9
    # perspective S*32/Z for Z = i/16 (then (5.11 value * inv) >> 16 = screen units)
    inv = [65535 if i < 5 else round(s * 32 / (i / 16)) for i in range(130)]
    kspr = round(MIS_SCALE_REF * 64 / (round(s * 32 / 2.0) >> 7))
    return dict(s=s, oy_f=oy, pos=pos, fwd=fwd, up=up, inv=inv, kspr=kspr,
                fz=round(-fwd[2] * 256), uz=round(-up[2] * 256),      # magnitudes /256 (both negative)
                oy=round(oy))


def absin(j):
    """|sin| in 1/255 (mulm divides by 255)"""
    return round(abs(math.sin(2 * math.pi * j / STEPS)) * 255)


def mis_float(r, th, phi, K):
    p = r * np.array([math.sin(th) * math.sin(phi), math.cos(th), math.sin(th) * math.cos(phi)])
    d = p - K["pos"]
    z = d @ K["fwd"]
    return K["s"] * d[0] / z, K["s"] * (d @ K["up"]) / z + K["oy_f"], z


def mis_state(r, th, K):
    """exact (float) H, A, B, R for distance r on ring theta."""
    pos, fwd, up = K["pos"], K["fwd"], K["up"]
    y = r * math.cos(th)
    return (r * math.sin(th), (y - pos[1]) * fwd[1] - pos[2] * fwd[2],
            (y - pos[1]) * up[1] - pos[2] * up[2], r)


def mis_project_int(H88, A88, B88, j, K):
    """missile_draw.s's projection, bit for bit: screen (x, y), sprite scale, or
    None if not drawable. Args are the top 16 bits (5.11); H >= 0. y is for
    vecx (on hardware missile_draw.s adds the anchor correction to K["oy"])."""
    def mulm(a, m, neg):             # ~ a * m / 255, rounded (a >= 0)
        p = a * m
        p += p >> 8
        v = (p + 128) >> 8
        return -v if neg else v

    def mulc(a, k):                  # a * k / 256, rounded, sign-magnitude
        v = (abs(a) * k + 128) >> 8
        return -v if a < 0 else v

    def mulhi(a, u):                 # (a * u) >> 16, rounded; sign-magnitude
        v = (abs(a) * u + 0x8000) >> 16
        return -v if a < 0 else v
    jc = (j + 60) % STEPS
    hs = mulm(H88, absin(j), j > STEPS // 2)
    hc = mulm(H88, absin(jc), jc > STEPS // 2)
    Z = A88 - mulc(hc, K["fz"])
    U = B88 - mulc(hc, K["uz"])
    if Z < round(MIS_ZMIN * 2048) or Z >= round(MIS_ZMAX * 2048):
        return None
    i, f = Z >> 7, Z & 127
    inv = K["inv"][i] - (((K["inv"][i] - K["inv"][i + 1]) * f + 64) >> 7)
    assert inv < 32768
    sx = mulhi(hs, inv)
    sy = mulhi(U, inv) + K["oy"]
    if abs(sx) > MIS_XLIM or not (MIS_YLO <= sy <= MIS_YHI):
        return None
    return sx, sy, max(1, ((inv >> 7) * K["kspr"]) >> 6)


def mis_hidden_r(th, phi, K, r_hi):
    """largest r (1..r_hi) at which the missile is behind the solid dome."""
    pos = K["pos"]
    ts = np.linspace(0.0, 0.999, 400)
    best = 1.0
    for r in np.arange(1.0, r_hi + 0.02, 0.02):
        p = r * np.array([math.sin(th) * math.sin(phi), math.cos(th), math.sin(th) * math.cos(phi)])
        q = pos + np.outer(ts, p - pos)
        if np.any((np.linalg.norm(q, axis=1) < 0.995) & (q[:, 1] > MIS_FLOOR_Y)):
            best = r
    return best


def mis_sprite(th, phi, K, length=None, width=None, out=False):
    """the dart at (theta, phi), as entries (is_line, dy, dx) from the tip,
    in DAC units at the scale mis_project_int returns for its depth. A
    missile points at the centre; a bullet (out=True) points away from it."""
    length = MIS_LEN if length is None else length
    width = MIS_WIDTH if width is None else width
    c = np.array([math.sin(th) * math.sin(phi), math.cos(th), math.sin(th) * math.cos(phi)])
    north = -np.array([math.cos(th) * math.sin(phi), -math.sin(th), math.cos(th) * math.cos(phi)])
    east = np.array([math.cos(phi), 0.0, -math.sin(phi)])
    r_rep = 1.6
    tip = r_rep * c
    base = tip + (-length if out else length) * c
    P = [tip] + [base + width * (math.cos(a) * north + math.sin(a) * east)
                 for a in (0, 2 * math.pi / 3, 4 * math.pi / 3)]
    P = np.array(P)
    pos = K["pos"]
    faces = [[1, 2, 3], [0, 1, 2], [0, 2, 3], [0, 3, 1]]
    ctr = P.mean(axis=0)
    vis = set()
    for f in faces:
        Q = P[f]
        n = np.cross(Q[1] - Q[0], Q[2] - Q[0])
        fc = Q.mean(axis=0)
        if n @ (fc - ctr) < 0:
            n = -n
        if n @ (pos - fc) > 0:
            for k in range(3):
                u, v = f[k], f[(k + 1) % 3]
                vis.add((min(u, v), max(u, v)))
    return sprite_entries(P, vis, K)


def sprite_entries(P, vis, K):
    """edges `vis` between world points P, seen from the camera, as entries
    (is_line, dy, dx) starting at P[0], in DAC units at the scale
    mis_project_int returns for P[0]'s depth."""
    pos, fwd, up = K["pos"], K["fwd"], K["up"]
    d = P - pos
    z = d @ fwd
    scr = np.column_stack([K["s"] * d[:, 0] / z, K["s"] * (d @ up) / z])
    inv = K["s"] * 32 / z[0]
    scale = ((int(inv) >> 7) * K["kspr"]) >> 6
    scr = (scr - scr[0]) * POS_SCALE / scale            # DAC units at that scale
    adj = defaultdict(set)
    for a, b in vis:
        adj[a].add(b)
        adj[b].add(a)
    out, cur = [], 0
    pen = scr[0].copy()

    def emit(p, line):
        nonlocal pen
        dy, dx = round(p[1] - pen[1]), round(p[0] - pen[0])
        for py, px in split((dy, dx), 127):
            out.append((line, py, px))
        pen = pen + np.array([dx, dy])
    while any(adj.values()):
        if not adj[cur]:
            live = [v for v in adj if adj[v]]
            odd = [v for v in live if len(adj[v]) % 2] or live
            cur = min(odd, key=lambda v: abs(scr[v] - pen).max())
            emit(scr[cur], False)
        while adj[cur]:
            w = max(adj[cur], key=lambda w: (len(adj[w]) - 1) % 2 == 1)
            adj[cur].discard(w)
            adj[w].discard(cur)
            emit(scr[w], True)
            cur = w
    return out


def make_missiles(pts, cells):
    K = mis_consts(pts)
    th, ring = mis_rings(cells)
    nr = len(th)
    order = sorted(range(cells["n"]), key=lambda i: ring[i])
    assert order == list(range(cells["n"])), "cells must be sorted by ring"
    ring_end = [sum(1 for i in range(cells["n"]) if ring[i] <= k) for k in range(nr)]
    phi_step = [(-cells["step"][i]) % STEPS for i in range(cells["n"])]

    def drawable(r, t, phi):
        H, A, B, R = mis_state(r, t, K)
        j = round(phi * STEPS / (2 * math.pi)) % STEPS
        return mis_project_int(round(H * 2048), round(A * 2048), round(B * 2048), j, K) is not None
    # start distance: beyond it the line is off screen at every rotation
    r_start, always = [], []          # always: the line is on screen at some rotation at any r
    for t in th:
        rs = None
        for r in np.arange(1.0, 8.0, 0.02):
            if not any(drawable(r2, t, math.radians(p)) for p in range(0, 360, 6)
                       for r2 in (r, r + 0.3, r + 0.8)):
                rs = round(r + 0.05, 2)
                break
        r_start.append(rs if rs is not None else MIS_R_MAX)
        always.append(rs is None)
    # Flights: a start state per ring (at r_spawn), and per ring the direction
    # dq = d(H, A, B, R)/dr as signed 16-bit (2^14 = 1.0, negated: inward).
    # missile_draw.s flight_inc makes the per-frame increments at launch:
    # inc = sign * ((|dir| * spd + 128) >> 8), spd = v * 2^13 (mis_speed).
    # The start is the same for every speed, so a flight lands (R <= 1.0) up
    # to one step past the exact cell centre (<= 0.022 radii: unseen).
    spd = [round(v * 8192) for v in MIS_SPEEDS]
    assert max(spd) <= 255
    start, mdir, frames = [], [], []
    for k, t in enumerate(th):
        # start off screen (plus the radar lead); rings whose lines are always
        # on screen somewhere (the low ones) start at the radar's edge
        r_spawn = RADAR_RANGE - 0.05 if always[k] else min(r_start[k] + MIS_LEAD, RADAR_RANGE - 0.05)
        start.append([round(x * FRAC) for x in mis_state(r_spawn, t, K)])
        dq = [x - x0 for x, x0 in zip(mis_state(2.0, t, K), mis_state(1.0, t, K))]
        mdir.append([-round(x * 16384) for x in dq])
        assert all(-32768 <= x < 32768 for x in mdir[-1])
        for sp in spd:             # model the flight: lands near the centre?
            inc = [(1 if x >= 0 else -1) * ((abs(x) * sp + 128) >> 8) for x in mdir[-1]]
            n = 0
            st = list(start[-1])
            while st[3] > FRAC:
                st = [a + b for a, b in zip(st, inc)]
                n += 1
            exact = mis_state(st[3] / FRAC, t, K)
            assert max(abs(a / FRAC - b) for a, b in zip(st, exact)) < 0.002, "flight drifts off its line"
            assert all(-0x800000 <= x < 0x800000 for x in start[-1] + inc)
            frames.append(n)
    # check the integer projection against exact projection along every flight
    worst = 0
    for k, t in enumerate(th):
        for j in range(0, STEPS, 7):
            for q in range(0, 101, 5):
                r = 1 + (r_start[k] - 1) * q / 100
                H, A, B, R = mis_state(r, t, K)
                got = mis_project_int(round(H * 2048), round(A * 2048), round(B * 2048), j, K)
                if got is None:
                    continue
                fx, fy, z = mis_float(r, t, 2 * math.pi * j / STEPS, K)
                e = max(abs(got[0] - fx), abs(got[1] - fy))
                worst = max(worst, e)
                assert e < (2 if z >= 1.1 else 4 if z >= 0.6 else 6), f"projection off by {e:.1f} units at depth {z:.2f}"
    # hidden behind the dome: r below occ[ring][j / 4] (j mirrored: 0..STEPS/2),
    # each entry the largest of the 4 steps it covers (a missile at the
    # dome's edge may stay hidden a little longer; never shows through it)
    occ = []
    for k, t in enumerate(th):
        row = []
        for j in range(STEPS // 2 + 1):
            rh = mis_hidden_r(t, 2 * math.pi * j / STEPS, K, min(r_start[k], 4.9)) if t > 0.01 else 1.0
            row.append(min(255, math.ceil((rh - 1) * 64)))
        occ += [max(row[q:q + 4]) for q in range(0, STEPS // 2 + 1, 4)]
    # sprites
    nst = MIS_SPRITE_PHI // 2 + 1
    sprites = [mis_sprite(t, 2 * math.pi * q / MIS_SPRITE_PHI, K) for t in th for q in range(nst)]
    # bullets: start with the head BUL_LEN above the cell, fly out until off
    # screen at every rotation (r_start)
    r0 = 1 + BUL_LEN
    bstart, binc, blife, bfar = [], [], [], []
    for k, t in enumerate(th):
        dR = round(BUL_SPEED * FRAC)
        bstart.append([round(x * FRAC) for x in mis_state(r0, t, K)])
        d = [round((x - x0) * dR) for x, x0 in zip(mis_state(2.0, t, K), mis_state(1.0, t, K))]
        d[3] = dR
        binc.append(d)
        blife.append(min(255, math.ceil((r_start[k] - r0) / BUL_SPEED)))
        bfar.append(min(255, math.ceil((RADAR_RANGE - r0) / BUL_SPEED)))   # to the radar's edge
    return dict(K=K, th=th, ring=ring, ring_end=ring_end, phi=phi_step, r_start=r_start,
                start=start, mdir=mdir, spd=spd, frames=frames, occ=occ, sprites=sprites, worst=worst,
                bstart=bstart, binc=binc, blife=blife, bfar=bfar, expl=make_explosion(),
                radar_k=radar_k(th), radar_frame=radar_frame(), cracks=make_cracks(K, th))


def radar_k(th):
    """per ring: (kh, kf, kv) with r32 = R * 32 (R < 8): radar x radius
    (r32 * kh) >> 8, y radius (r32 * kf) >> 8, stick height (r32 * kv) >> 8,
    in DAC units at RADAR_SCALE (radar.s)."""
    out = []
    for t in th:
        kh = 8 * RADAR_R / RADAR_RANGE * math.sin(t)
        kv = 8 * RADAR_H / RADAR_RANGE * math.cos(t) ** RADAR_H_POW
        out += [round(kh), round(kh * RADAR_FLAT), max(0, round(kv))]
    assert max(out) <= 255
    # the blip's way back to the centre is one move: |y| and |x| <= 127
    assert RADAR_R * RADAR_FLAT + RADAR_H + 1 <= 127 and RADAR_R + 12 <= 127
    return out


def make_cracks(K, th):
    """crack_pos (per ring, 31 (x, y) pairs, every 4th j), crack_look (per ring, 16
    (scale, variant) pairs by j / 8) and the crack shapes, crack_shapes[variant
    * 4 + shape], as entries in DAC units. Variant: 0..3 = CRACK_ASPECTS
    vertically squashed, 4..7 = horizontally."""
    pos = []
    for t in th:
        for j in range(0, STEPS // 2 + 1, 4):
            a = 2 * math.pi * j / STEPS
            c = np.array([math.sin(t) * math.sin(a), math.cos(t), math.sin(t) * math.cos(a)])
            x, y, _ = mis_float(1.0, t, a, K)
            if c @ (K["pos"] - c) <= 0:
                pos += [-128, 0]
            else:
                x, y = round(x), round(y - K["oy_f"])
                assert -127 <= x <= 127 and -128 <= y <= 127
                pos += [x, y]

    # the blend (cracks.s): (a (4 - f) + b f) / 4, f = j & 3; check it
    row = STEPS // 8 + 1
    worst = 0
    for r, t in enumerate(th):
        for j in range(STEPS // 2 + 1):
            k, f = j // 4, j % 4
            a, b = pos[2 * (r * row + k):2 * (r * row + k) + 2], pos[2 * (r * row + min(k + 1, row - 1)):][:2]
            if a[0] == -128 or (f and b[0] == -128):
                continue
            got = [(a[q] * (4 - f) + b[q] * f) >> 2 for q in (0, 1)]
            x, y, _ = mis_float(1.0, t, 2 * math.pi * j / STEPS, K)
            worst = max(worst, abs(got[0] - x), abs(got[1] - (y - K["oy_f"])))
    assert worst < 2.0, f"crack position blend off by {worst:.2f}"

    def axes(t, a):                    # projected size of a unit step east, north
        e = 1e-3
        p0 = np.array(mis_float(1.0, t, a, K)[:2])
        n = np.array(mis_float(1.0, t - e, a, K)[:2]) - p0 if t > e else \
            np.array(mis_float(1.0, e, a + math.pi, K)[:2]) - p0
        if t > e:
            ea = np.array(mis_float(1.0, t, a + e / math.sin(t), K)[:2]) - p0
        else:
            ea = np.array(mis_float(1.0, e, a + math.pi / 2, K)[:2]) - p0
        # screen extents: horizontal and vertical reach of the tile's surface
        h = math.hypot(ea[0], n[0]) / e
        v = math.hypot(ea[1], n[1]) / e
        return h, v
    look_raw = [[axes(t, 2 * math.pi * jj * 8 / STEPS) for jj in range(16)] for t in th]
    big = max(max(h, v) for row in look_raw for h, v in row)
    look = []
    for row in look_raw:
        for h, v in row:
            m = max(h, v)
            r = min(h, v) / m
            lev = min(range(len(CRACK_ASPECTS)), key=lambda q: abs(CRACK_ASPECTS[q] - r))
            look += [max(3, round(CRACK_SCALE * m / big)), (lev if v < h else len(CRACK_ASPECTS) + lev)]
    k = POS_SCALE / CRACK_SCALE
    shapes = []
    for vert in (True, False):
        for asp in CRACK_ASPECTS:
            for sh in CRACK_SHAPES:
                p = [(round(x * k * (1 if vert else asp)), round(y * k * (asp if vert else 1))) for x, y in sh]
                ents = [(False, p[0][1], p[0][0])]
                ents += [(True, b[1] - a[1], b[0] - a[0]) for a, b in zip(p, p[1:])]
                ents.append((False, -p[-1][1], -p[-1][0]))     # back to the centre (cracks are chained)
                assert all(abs(dy) <= 127 and abs(dx) <= 127 for _, dy, dx in ents)
                shapes.append(ents)
    return dict(pos=pos, look=look, shapes=shapes)


def make_hud():
    """glyph entry lists in HUD_GLYPHS order: (is_line, dy, dx) in DAC units
    at HUD_SCALE, from the glyph's lower left to the next glyph's."""
    out = []
    for name, strokes in HUD_GLYPHS.items():
        adv = 8 if name == "dome" else HUD_ADVANCE
        pen = (0, 0)
        ents = []
        for st in strokes:
            for k, p in enumerate(st):
                q = (round(p[0] * HUD_UNIT), round(p[1] * HUD_UNIT))
                if k > 0:                  # a line (a dot if it doesn't move)
                    ents.append((True, q[1] - pen[1], q[0] - pen[0]))
                elif q != pen:             # pen up to the stroke's start
                    ents.append((False, q[1] - pen[1], q[0] - pen[0]))
                pen = q
        ents.append((False, -pen[1], adv * HUD_UNIT - pen[0]))
        assert all(abs(dy) <= 127 and abs(dx) <= 127 for _, dy, dx in ents)
        out.append((name, ents))
    return out


def radar_cscale():
    """scale of the move to the radar's centre (both DAC values <= 127)"""
    return math.ceil(max(abs(RADAR_CX), abs(RADAR_CY)) * POS_SCALE / 127)


def radar_frame():
    """the ellipse and a small dome at its centre, from the centre and back,
    at RADAR_ESCALE: entries (is_line, dy, dx)."""
    k = RADAR_SCALE / RADAR_ESCALE
    rx, ry = RADAR_R * k, RADAR_R * RADAR_FLAT * k
    pts = [(rx * math.cos(2 * math.pi * i / RADAR_SEGS), ry * math.sin(2 * math.pi * i / RADAR_SEGS))
           for i in range(RADAR_SEGS + 1)]
    pts = [(round(x), round(y)) for x, y in pts]
    out = []
    for d in split((0, pts[0][0]), 127):
        out.append((False, d[0], d[1]))
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        for d in split((y1 - y0, x1 - x0), 127):
            out.append((True, d[0], d[1]))
    for d in split((0, -pts[0][0]), 127):
        out.append((False, d[0], d[1]))
    # the dome: a roof from its rim (radius sin(RIM), height cos(RIM)) to its peak
    s = RADAR_R / RADAR_RANGE * k
    rim = math.radians(RIM_DEG or CAP_DEG)
    w = round(s * math.sin(rim))
    h0 = round(RADAR_H / RADAR_RANGE * k * math.cos(rim))
    h1 = round(RADAR_H / RADAR_RANGE * k)
    if RADAR_ROOF:
        out += [(False, h0, -w), (True, h1 - h0, w), (True, h0 - h1, w), (False, -h0, -w)]
    assert all(abs(dy) <= 127 and abs(dx) <= 127 and dy != -128 for _, dy, dx in out)
    return out


def make_explosion():
    """EXPL_STEPS frames of EXPL_PIECES fragments flying out and spinning,
    plus a star flash in the first two: entries from the centre, in DAC
    units at EXPL_SCALE."""
    k = POS_SCALE / EXPL_SCALE                       # DAC units per screen unit
    frames = []
    for t in range(EXPL_STEPS):
        pen = np.zeros(2)
        out = []

        def go(p, line):
            nonlocal pen
            dy, dx = round(p[1] - pen[1]), round(p[0] - pen[0])
            for py, px in split((dy, dx), 127):
                out.append((line, py, px))
            pen = pen + np.array([dx, dy])
        if t < 2:                                    # flash: a 4-line star
            for a in range(4):
                u = np.array([math.cos(a * math.pi / 4), math.sin(a * math.pi / 4)]) * 12 * k
                go(u, False)
                go(-u, True)
        dist = (4 + 36 * (1 - (1 - t / (EXPL_STEPS - 1)) ** 2)) * k   # fast, then slowing
        for i in range(EXPL_PIECES):
            a = 2 * math.pi * (i + 0.3 * (i % 2)) / EXPL_PIECES
            spin = a + 0.5 * t * (1 if i % 2 else -1)
            c = np.array([math.cos(a), math.sin(a)]) * dist * (0.8 + 0.4 * ((i * 7) % 5) / 4)
            h = np.array([math.cos(spin), math.sin(spin)]) * 4 * k
            go(c - h, False)
            go(c + h, True)
        frames.append(out)
    return frames


def write_missiles(out, M, cells):
    K = M["K"]
    nr = len(M["th"])
    ns = len(MIS_SPEEDS)
    nst = MIS_SPRITE_PHI // 2 + 1
    with open(os.path.join(out, "missile_data.h"), "w") as f:
        f.write(f"""// missile_data.h: enemy missile tables (generated by tools/gen_dome.py; do not edit)
#ifndef MISSILE_DATA_H
#define MISSILE_DATA_H

#define MIS_RINGS       {nr}     // rings of cells by angle from the peak (0 = the peak)
#define MIS_SPEEDS      {ns}      // speed indices (sphere radii per frame: {", ".join(str(v) for v in MIS_SPEEDS)})

// cells are numbered by ring: ring k is cells mis_ring_end[k-1] .. mis_ring_end[k]-1
extern const unsigned char mis_ring_end[MIS_RINGS];
extern const unsigned char mis_cell_ring[NCELLS];
extern const unsigned char mis_cell_phi[NCELLS];     // cell azimuth, in rotation steps

// flight start (H, A, B, R; 3 bytes each) by ring, the flight's direction
// (4 x signed 16-bit, big-endian) by ring and the speeds (v * 2^13): the game
// makes the per-frame increments with flight_inc (missile.h)
extern const unsigned char mis_start[MIS_RINGS][12];
extern const unsigned char mis_dir[MIS_RINGS][8];
extern const unsigned char mis_speed[MIS_SPEEDS];

// screen y of the sphere centre's projection offset (vecx), and the dome
// anchor's nominal distance (missile.c corrects for the console's ramp tail)
#define MIS_OY          ({K["oy"]})
#define MIS_ANCHOR_NOM  {round(abs(ANCHOR_Y))}

// bullets: flight start and increments by ring, and frames until off screen
extern const unsigned char bul_start[MIS_RINGS][12];
extern const unsigned char bul_inc[MIS_RINGS][12];
extern const unsigned char bul_life[MIS_RINGS];
// ...and until the radar's edge (fired at a missile on the same line)
extern const unsigned char bul_life_far[MIS_RINGS];

// broken tiles (cracks.s): tile-centre positions by ring and azimuth, the
// crack's scale and flattening by ring and azimuth / 8, the shapes (count,
// entries)
extern const unsigned char crack_pos[];
extern const unsigned char crack_look[];
extern const unsigned char *const crack_shapes[];

// HUD glyphs (hud.s): digits 0-9, then '%' (HUD_PCT), a small dome (HUD_DOME), a life (HUD_SHIP)
#define HUD_PCT         10
#define HUD_DOME        11
#define HUD_SHIP        12
extern const unsigned char *const hud_glyphs[13];

// radar (radar.s): per ring kh, kf, kv; the ellipse list (count, entries)
extern const unsigned char radar_k[MIS_RINGS * 3];
#define RADAR_RMAX      {round(RADAR_RANGE * 8)}     // R's top byte (R * 8) at the radar's edge
extern const unsigned char radar_frame[];

// explosion animation: EXPL_STEPS lists (count, entries), each shown EXPL_HOLD frames
#define EXPL_STEPS      {EXPL_STEPS}
#define EXPL_HOLD       {EXPL_HOLD}

#endif // MISSILE_DATA_H
""")
    with open(os.path.join(out, "missile_data.c"), "w") as f:
        f.write("// missile_data.c: generated by tools/gen_dome.py; do not edit\n")
        f.write('#include "dome_data.h"\n#include "missile_data.h"\n\n')

        def arr(name, vals, per=16, typ="unsigned char"):
            f.write(f"const {typ} {name} = {{\n")
            for k in range(0, len(vals), per):
                f.write("  " + ", ".join(str(v) for v in vals[k:k + per]) + ",\n")
            f.write("};\n\n")
        arr("mis_ring_end[MIS_RINGS]", M["ring_end"])
        arr("mis_cell_ring[NCELLS]", M["ring"])
        arr("mis_cell_phi[NCELLS]", M["phi"])
        b3 = lambda x: [(x >> 16) & 255, (x >> 8) & 255, x & 255]
        f.write("const unsigned char mis_start[MIS_RINGS][12] = {\n")
        for s0 in M["start"]:
            f.write("  {" + ", ".join(str(v) for x in s0 for v in b3(x)) + "},\n")
        f.write("};\n\nconst unsigned char mis_dir[MIS_RINGS][8] = {\n")
        for d in M["mdir"]:
            f.write("  {" + ", ".join(f"{(x >> 8) & 255},{x & 255}" for x in d) + "},\n")
        f.write("};\n\n")
        arr("mis_speed[MIS_SPEEDS]", M["spd"])
        f.write("const unsigned char bul_start[MIS_RINGS][12] = {\n")
        for s0 in M["bstart"]:
            f.write("  {" + ", ".join(str(v) for x in s0 for v in b3(x)) + "},\n")
        f.write("};\n\nconst unsigned char bul_inc[MIS_RINGS][12] = {\n")
        for d in M["binc"]:
            f.write("  {" + ", ".join(str(v) for x in d for v in b3(x)) + "},\n")
        f.write("};\n\n")
        arr("bul_life[MIS_RINGS]", M["blife"])
        arr("bul_life_far[MIS_RINGS]", M["bfar"])
        Cr = M["cracks"]
        arr(f"crack_pos[{len(Cr['pos'])}]", [v & 255 for v in Cr["pos"]])
        arr(f"crack_look[{len(Cr['look'])}]", Cr["look"])
        for i, ents in enumerate(Cr["shapes"]):
            body = " ".join((f"{dy & 255},{dx & 255}," if l else f"128,{dy & 255},{dx & 255},")
                            for l, dy, dx in ents)
            f.write(f"static const unsigned char crack{i}[] = {{ {len(ents)}, {body} }};\n")
        f.write(f"const unsigned char *const crack_shapes[{len(Cr['shapes'])}] = {{ "
                + ", ".join(f"crack{i}" for i in range(len(Cr["shapes"]))) + " };\n\n")
        hud = make_hud()
        for name, ents in hud:
            body = " ".join((f"{dy & 255},{dx & 255}," if l else f"128,{dy & 255},{dx & 255},")
                            for l, dy, dx in ents)
            f.write(f"static const unsigned char glyph_{'pct' if name == '%' else 'd' + name if name.isdigit() else name}[] = {{ {len(ents)}, {body} }};\n")
        names = ['pct' if n == '%' else 'd' + n if n.isdigit() else n for n, _ in hud]
        f.write(f"const unsigned char *const hud_glyphs[{len(hud)}] = {{ " + ", ".join(f"glyph_{n}" for n in names) + " };\n\n")
        arr(f"radar_k[{len(M['radar_k'])}]", M["radar_k"])
        ents = M["radar_frame"]
        body = " ".join((f"{dy & 255},{dx & 255}," if l else f"128,{dy & 255},{dx & 255},")
                        for l, dy, dx in ents)
        f.write(f"const unsigned char radar_frame[] = {{ {len(ents)}, {body} }};\n\n")
        # tables for missile_draw.s
        # |sin| for a quarter turn: missile_draw.s absin folds j into 0..60
        q = STEPS // 4
        for j in range(STEPS):
            jf = j % (STEPS // 2)
            assert absin(j) == absin(jf if jf <= q else STEPS // 2 - jf)
        arr(f"mis_absin[{q + 1}]", [absin(j) for j in range(q + 1)])
        inv = K["inv"]
        f.write("const unsigned char mis_inv[260] = {   // perspective: S*32/Z, Z = i/16, big-endian\n")
        for k in range(0, 130, 8):
            f.write("  " + ", ".join(f"{v >> 8},{v & 255}" for v in inv[k:k + 8]) + ",\n")
        f.write("};\n\n")
        arr(f"mis_occ[{len(M['occ'])}]", M["occ"])         # (-mint8: no int products in sizes)
        for i, ents in enumerate(M["sprites"]):
            body = " ".join((f"{dy & 255},{dx & 255}," if l else f"128,{dy & 255},{dx & 255},")
                            for l, dy, dx in ents)
            f.write(f"static const unsigned char mspr{i}[] = {{ {len(ents)}, {body} }};\n")
        f.write(f"\nconst unsigned char *const mis_sprites[{len(M['sprites'])}] = {{\n  ")
        f.write(", ".join(f"mspr{i}" for i in range(len(M["sprites"]))))
        f.write("\n};\n\n")

        def lists(name, items, tag):
            for i, ents in enumerate(items):
                body = " ".join((f"{dy & 255},{dx & 255}," if l else f"128,{dy & 255},{dx & 255},")
                                for l, dy, dx in ents)
                f.write(f"static const unsigned char {tag}{i}[] = {{ {len(ents)}, {body} }};\n")
            f.write(f"\nconst unsigned char *const {name}[{len(items)}] = {{\n  ")
            f.write(", ".join(f"{tag}{i}" for i in range(len(items))))
            f.write("\n};\n\n")
        lists("expl_frames", M["expl"], "expl")
    with open(os.path.join(out, "missile_cfg.inc"), "w") as f:
        f.write(f"""; missile_cfg.inc: generated by tools/gen_dome.py; do not edit (as6809)
MIS_STEPS       = {STEPS}
MIS_HALF        = {STEPS // 2}
MIS_QUARTER     = {STEPS // 4}
MIS_FZ          = {K["fz"]}       ; -fwd.z * 256 (fwd.z < 0)
MIS_UZ          = {K["uz"]}       ; -up.z * 256 (up.z < 0)
MIS_ZMIN        = {round(MIS_ZMIN * 2048)}
MIS_ZMAX        = {round(MIS_ZMAX * 2048)}
MIS_XLIM        = {MIS_XLIM}
MIS_YLO         = {MIS_YLO}
MIS_YHI         = {MIS_YHI}
MIS_KSPR        = {K["kspr"]}
MIS_SPR_PHI     = {MIS_SPRITE_PHI}
MIS_SPR_STORED  = {nst}
MIS_OCC_ROW     = {STEPS // 8 + 1}
EXPL_SCALE      = {EXPL_SCALE:#04x}
BUL_K           = {round(BUL_SIZE * 16)}        ; bullet scale = missile scale * BUL_K / 16
CRACK_ROW       = {STEPS // 8 + 1}        ; crack_pos entries per ring (every 4th j)
HUD_SCALE       = {HUD_SCALE:#04x}
RADAR_SCALE     = {RADAR_SCALE:#04x}
RADAR_ESCALE    = {RADAR_ESCALE:#04x}
RADAR_CSCALE    = {radar_cscale():#04x}
RADAR_CX        = {round(RADAR_CX * POS_SCALE / radar_cscale())}
RADAR_CY        = {round(RADAR_CY * POS_SCALE / radar_cscale())}
RADAR_RMAX      = {round(RADAR_RANGE * 8)}      ; R's top byte (R * 8) at the edge
""")


def main():
    global FREQ, CAP_DEG, RIM_DEG, POS_SCALE, CHUNK_OVERHEAD, X_HALF, Y_BOTTOM, LINE_MUL, ANCHOR_Y, ANCHOR_DAC, ANCHOR_SCALE
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="src")
    ap.add_argument("--preview")
    ap.add_argument("--step", type=int, default=0)
    ap.add_argument("--freq", type=int, help="override FREQ")
    ap.add_argument("--cap", type=float, help="override CAP_DEG")
    ap.add_argument("--rim", type=float, help="override RIM_DEG (whole polygons, no flat cut)")
    ap.add_argument("--pos-scale", type=lambda v: int(v, 0), help="override POS_SCALE (screen size)")
    ap.add_argument("--line-mul", type=int, help="override LINE_MUL")
    ap.add_argument("--x-half", type=int, help="override X_HALF")
    ap.add_argument("--y-bottom", type=int, help="override Y_BOTTOM (default: centred)")
    ap.add_argument("--ship", type=int, help="preview: also draw the ship at latitude index N")
    args = ap.parse_args()
    FREQ = args.freq or FREQ
    if args.cap:
        CAP_DEG, RIM_DEG = args.cap, None
    RIM_DEG = args.rim or RIM_DEG
    POS_SCALE = args.pos_scale or POS_SCALE
    CHUNK_OVERHEAD = 80 + POS_SCALE
    X_HALF = args.x_half or X_HALF
    Y_BOTTOM = args.y_bottom if args.y_bottom is not None else Y_BOTTOM
    LINE_MUL = args.line_mul or LINE_MUL
    assert STEPS % 10 == 0

    pts, edges, faces = build_mesh()
    s, oy = screen_fit(pts)
    ys = np.concatenate([project(pts, st)[0][:, 1] * s + oy for st in range(VIEWS)])
    if ys.min() < -127 or ys.max() > 127:
        want = (ys.min() + ys.max()) / 2
        ANCHOR_SCALE = math.ceil(abs(want) * POS_SCALE / 127)
        assert ANCHOR_SCALE <= 255
        ANCHOR_DAC = round(want * POS_SCALE / ANCHOR_SCALE)
        ANCHOR_Y = ANCHOR_DAC * ANCHOR_SCALE / POS_SCALE
    best = None
    for mul in ([LINE_MUL] if LINE_MUL else (1, 2, 4, 8)):
        views = make_views(pts, edges, faces, mul, range(STORED))
        worst = max(view_cost(c, mul)[0] for c, _ in views)
        if best is None or worst < best[1]:
            best = (mul, worst, views)
    mul, worst, views = best
    check_mirror(pts, edges, faces, mul)
    nfaces = defaultdict(int)
    for f in faces:
        nfaces[len(f)] += 1
    rom = sum(sum(3 + sum(2 if l else 3 for l, _, _ in e) for _, _, e in c) + 1 for c, _ in views) + 2 * STORED
    vis = [n for _, n in views]
    rim = f"whole polygons to {RIM_DEG}" if RIM_DEG else f"flat cut {CAP_DEG}"
    print(f"dome: GP({FREQ},0) {rim} deg: {len(pts)} points, {len(edges)} edges, "
          f"faces by side count {dict(sorted(nfaces.items()))}; visible edges {min(vis)}..{max(vis)}; "
          f"{STORED} stored views (of {VIEWS}); LINE_MUL {mul}; chunks/view "
          f"{min(len(c) for c, _ in views)}..{max(len(c) for c, _ in views)}; "
          f"worst ~{worst} cycles (model); anchor {ANCHOR_DAC} at scale {ANCHOR_SCALE}; ROM {rom} bytes")
    cells = make_cells(pts, faces)      # sets SHIP_MAX_DEG: lowest ship view = lowest cell
    start = min(range(1, cells["n"]), key=lambda i: (abs(cells["lat"][i] - 30),
                                                    min(cells["step"][i], STEPS - cells["step"][i])))
    print(f"cells: {cells['n']} walkable (peak = 0), lowest centre {SHIP_MAX_DEG:.1f} deg, start cell {start}")
    ships = make_ship_views(pts, mul)
    print(f"ship: {SHIP_STEPS} latitude views, {max(sum(len(e) for _, _, e in c) for c in ships)} "
          f"entries max, ROM {sum(sum(3 + sum(2 if l else 3 for l, _, _ in e) for _, _, e in c) + 1 for c in ships) + 2 * SHIP_STEPS} bytes")
    M = make_missiles(pts, cells)
    msp = sum(1 + sum(2 if l else 3 for l, _, _ in e) for e in M["sprites"])
    bsp = sum(1 + sum(2 if l else 3 for l, _, _ in e) for e in M["expl"])
    print(f"explosion: {bsp} bytes; explosion {max(len(e) for e in M['expl'])} entries max; "
          f"bullet life {M['blife']} frames")
    print(f"missiles: {len(M['th'])} rings, start r {[round(float(r), 2) for r in M['r_start']]}, projection error <= {M['worst']:.2f} units, "
          f"sprites {len(M['sprites'])} ({msp} bytes, max {max(len(e) for e in M['sprites'])} entries)")
    if args.preview:
        st = args.step % VIEWS
        segs = (view_segments(views[st][0], mul) if st < STORED
                else view_segments(views[VIEWS - st][0], mul, mirror=True))
        if args.ship is not None:
            segs += view_segments(ships[args.ship], mul)
        render(args.preview, segs)
        return

    with open(os.path.join(args.out, "dome_data.h"), "w") as f:
        f.write(f"""// dome_data.h: geodesic dome views (generated by tools/gen_dome.py; do not edit)
#ifndef DOME_DATA_H
#define DOME_DATA_H

#define DOME_STEPS      {STEPS}     // rotation steps per turn
#define DOME_VIEWS      {VIEWS}      // distinct views (5-fold symmetry): step % DOME_VIEWS
#define DOME_STORED     {STORED}      // views 0..DOME_STORED-1 stored; view v beyond = mirror of DOME_VIEWS-v
#define DOME_LINE_MUL   {mul}      // strokes are drawn at scale {POS_SCALE // mul:#04x}
// Scale for chunk starts so they agree with the strokes on a console whose ramp
// runs `tail` cycles past T1: POS_SCALE + (LINE_MUL-1)*tail. DEFAULT: a typical
// console (tail {TAIL_DEFAULT:.2f}); MINE: one measured console (tail {TAIL_MINE:.2f}); vecx has no
// tail: DOME_POS_NOMINAL. DOME_POS_MIN..MAX: the calibration range.
#define DOME_POS_NOMINAL {POS_SCALE}
#define DOME_ANCHOR_DAC  ({ANCHOR_DAC})     // the chunks' anchor move (dome_draw.s)
#define DOME_ANCHOR_SCALE {ANCHOR_SCALE}
#define DOME_POS_DEFAULT {round(POS_SCALE + (mul - 1) * TAIL_DEFAULT)}
#define DOME_POS_MINE   {round(POS_SCALE + (mul - 1) * TAIL_MINE)}
#define DOME_POS_MIN    {POS_SCALE - POS_SCALE // 4}
#define DOME_POS_MAX    {min(255, POS_SCALE + (mul - 1) * 8 + POS_SCALE // 4)}

// The scale dome_draw.s uses for chunk starts (defined in the game, calibratable).
extern unsigned char dome_pos_scale;

// dome_views[v]: chunks of (n, y, x, n entries: dy,dx | 0x80,dy,dx), then 0.
extern const unsigned char *const dome_views[DOME_STORED];

#define SHIP_STEPS      {SHIP_STEPS}      // ship latitudes: 0 = on the peak .. SHIP_STEPS-1 = lowest cell
// ship_views[i]: the ship on the front meridian at latitude i (same format).
extern const unsigned char *const ship_views[SHIP_STEPS];

// Movement: the ship rests on cell centres (whole polygons). Cell 0 is the peak.
#define NCELLS          {cells["n"]}
#define CELL_START      {start}
#define STICK_DIRS      {STICK_DIRS}      // 0 = right, 8 = up, 16 = left, 24 = down
#define MOVE_FRAMES     {MOVE_FRAMES}      // a move to a neighbouring cell lasts this many frames
extern const unsigned char cell_step[NCELLS];   // dome rotation that puts the cell in front
extern const unsigned char cell_lat[NCELLS];    // ship latitude of the cell centre
// cell_adj[c]: up to 6 (screen direction in 1/256 turn, neighbour) pairs,
// neighbour 255 = none; directions on screen in the cell's resting view.
// The game moves to the one nearest the stick, within 45 degrees.
extern const unsigned char cell_adj[NCELLS][12];
// peak_down[step % DOME_VIEWS]: the ring cell nearest the front, for "down" at the peak.
extern const unsigned char peak_down[DOME_VIEWS];
// stick_q[ay*16 + ax]: direction (0..8) of the analog stick in the first
// quadrant, ax = |x| >> 3, ay = |y| >> 3; 255 = dead zone. Mirror for x, y < 0.
extern const unsigned char stick_q[256];

#endif // DOME_DATA_H
""")
    with open(os.path.join(args.out, "dome_data.c"), "w") as f:
        f.write("// dome_data.c: generated by tools/gen_dome.py; do not edit\n")
        f.write(f"// FREQ={FREQ} RIM_DEG={RIM_DEG} CAP_DEG={CAP_DEG} CAM_ELEV_DEG={CAM_ELEV_DEG} CAM_DIST={CAM_DIST} "
                f"LOOK_Y={LOOK_Y} STEPS={STEPS} LINE_MUL={mul}\n")
        f.write('#include "dome_data.h"\n\n')
        for v, (chunks, _) in enumerate(views):
            write_chunks(f, f"view{v}", chunks)
        f.write("\nconst unsigned char *const dome_views[DOME_STORED] = {\n  ")
        f.write(", ".join(f"view{v}" for v in range(STORED)))
        f.write("\n};\n\n")
        for i, chunks in enumerate(ships):
            write_chunks(f, f"ship{i}", chunks)
        f.write("\nconst unsigned char *const ship_views[SHIP_STEPS] = {\n  ")
        f.write(", ".join(f"ship{i}" for i in range(SHIP_STEPS)))
        f.write("\n};\n")

        def arr(name, vals, per=16):
            f.write(f"\nconst unsigned char {name} = {{\n")
            for k in range(0, len(vals), per):
                f.write("  " + ", ".join(str(v) for v in vals[k:k + per]) + ",\n")
            f.write("};\n")
        arr("cell_step[NCELLS]", cells["step"])
        arr("cell_lat[NCELLS]", cells["lat"])
        f.write("\nconst unsigned char cell_adj[NCELLS][12] = {\n")
        for row in cells["adj"]:
            f.write("  {" + ", ".join(f"{a},{j}" for a, j in row) + "},\n")
        f.write("};\n")
        arr("peak_down[DOME_VIEWS]", cells["peak_down"])
        arr("stick_q[256]", cells["stick"], 16)
    with open(os.path.join(args.out, "dome_cfg.inc"), "w") as f:
        f.write(f"""; dome_cfg.inc: generated by tools/gen_dome.py; do not edit (as6809)
DOME_VIEWS      = {VIEWS}
DOME_STORED     = {STORED}
DOME_LINE_SCALE = {POS_SCALE // mul:#04x}
DOME_ANCHOR_Y   = {ANCHOR_DAC}
DOME_ANCHOR_SCALE = {ANCHOR_SCALE:#04x}
SHIP_STEPS      = {SHIP_STEPS}
MOVE_FRAMES     = {MOVE_FRAMES}
""")
    write_missiles(args.out, M, cells)
    print(f"wrote {args.out}/dome_data.h, dome_data.c, dome_cfg.inc, missile_data.h, missile_data.c, missile_cfg.inc")


if __name__ == "__main__":
    main()
