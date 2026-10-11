# Vector budget: what real Vectrex games draw per frame

Measured 2026-10-03 by running commercial (GCE, 1982–83) and homebrew ROMs
in an instrumented vecx core (`tools/vecxstat/`). Use it to set realistic
targets for a scene before writing code.

## How it was measured

`tools/vecxstat/build.sh` builds the vecx libretro core with a small patch
(`vecxstat.patch`) that, on every BIOS `Wait_Recal` (one game-loop
iteration), reports to stderr:

- the cycles since the previous `Wait_Recal`,
- **lines**: lit beam segments the emulator emitted,
- **+text**: segments emitted while the CPU was inside BIOS `Print_Str`
  ($F495–$F510); these are not counted in lines,
- **ink**: total lit length, in screen widths,
- **beam-on**: cycles the beam was lit.

`tools/vecxstat/survey.sh ROM...` boots each ROM headless and presses
4/1 around frames 700–960 to get GCE games past their select screen. It then
moves the stick and fires, and summarizes frames 1100–2200 (gameplay). Check
`build/vecxstat/survey/<name>.png` to confirm the game was in gameplay.

Caveats:
- A segment is one straight lit run in vecx. A BIOS vector list of n
  vectors yields about n segments.
- Games that never call BIOS `Wait_Recal` (Telengard, Karl Quappe) report
  nothing.
- Homebrew text drawn by custom routines counts as lines.
- vecx is an emulator. Timing is cycle-accurate for the CPU and VIA, but
  analog drift is idealized.

## Results (gameplay)

Hz = game-loop rate (1.5 MHz ÷ median cycles per loop; 50 Hz is the
30,000-cycle `Wait_Recal` frame).

### Commercial (GCE 1982–83)

| Game | Hz | lines med / p90 | +text | beam-on (% of loop) |
|---|---:|---:|---:|---:|
| Berzerk | 32.6 | 172 / 177 | 61 | 12% |
| Clean Sweep | 48.6 | 183 / 188 | 21 | 12% |
| Mr. Boston (Clean Sweep promo) | 50.0 | 178 / 184 | 43 | 11% |
| HeadsUp | 36.4 | 170 / 170 | 104 | 25% |
| Armor Attack | 49.7 | 127 / 127 | 0 | 34% |
| Dark Tower | 47.9 | 118 / 119 | 36 | 23% |
| Fortress of Narzod | 32.9 | 108 / 140 | 12 | 22% |
| StarHawk | 35.1 | 102 / 113 | 87 | 24% |
| Web Wars | 26.6 | 133 / 157 | 124 | 19% |
| Pole Position | 35.7 | 91 / 91 | 132 | 31% |
| Cosmic Chasm | 33.2 | 90 / 122 | 30 | 11% |
| Spike | 34.9 | 70 / 73 | 31 | 11% |
| Scramble | 31.5 | 69 / 88 | 48 | 11% |
| Mine Storm II | 49.8 | 54 / 54 | 12 | 8% |
| Hyperchase | 33.3 | 48 / 73 | 34 | 7% |
| Rip Off | 33.3 | 44 / 46 | 12 | 3% |
| Blitz | 32.1 | 50 / 60 | 184 | 9% |
| Bedlam | 29.9 | 36 / 74 | 61 | 4% |

### Homebrew

| Game | Lang | Hz | lines med / p90 | +text | beam-on |
|---|---|---:|---:|---:|---:|
| Shongololo (Malban) | asm | 49.9 | 437 / 474 | 0 | 33% |
| Black Hole (particles) | asm | 49.0 | 227 / 239 | 0 | 23% |
| Donkey Kong (VIDE) | asm | 50.0 | 158 / 158 | 0 | 20% |
| **Bouncer (VIDE)** | **gcc6809 C** | **50.0** | **152 / 152** | 0 | 12% |
| **Lode Runner (VIDE)** | **gcc6809 C** | **50.0** | **117 / 118** | 0 | 21% |
| VRelease (Malban) | asm | 50.0 | 67 / 97 | 0 | 10% |
| Demo3d (VIDE 3D) | gcc6809 C | 47.9 | 54 / 93 | 0 | 20% |
| Vector Twist / Spike Vortex (Garry) | asm | 28.5 | 52 / 88 | 188 | 30% |
| Circus (Garry) | asm | 25.0 | 59 / 62 | 44 | 22% |

Outside gameplay (title/attract screens, not in the tables): Telengard's
title 539 lines, Karl Quappe 580, both at 50 Hz.

## What this means for a new game

- **Commercial games drew about 50–180 vectors (plus score text).** Many
  ran their busy gameplay at **~30–35 Hz**: the loop took ~45,000 cycles
  instead of 30,000 (`Vec_Rfrsh` stayed at the default 30,000;
  `Wait_Recal` simply returns late). That rate was accepted on hardware
  but flickers visibly. Below ~25 Hz the flicker is bad, and that's where an
  overloaded scene ends up.
- **Optimized asm homebrew reaches 200–450 lines at 50 Hz**, all of it
  from precomputed vector lists drawn back to back.
- **gcc6809 C games hold 50 Hz with ~120–150 lines** (Bouncer, Lode
  Runner) when the per-frame math is light and drawing goes through BIOS
  list calls.
- **Line count is rarely limited by beam time.** Beam-on is only 3–35% of
  the loop. A line costs `scale` cycles no matter how long it is, so games
  draw with a small scale and large list values. The rest of the budget
  goes to CPU work: setting up each vector, `Reset0Ref`/moves, and game
  logic.

Reasonable targets for this template's projects:
- Main scene **≤ ~150 lines** at **50 Hz** (≤ 30,000 cycles per loop,
  including game logic and sound). Anything heavier goes to asm and
  precomputed lists.
- Never let gameplay drop below ~33 Hz (`make test` "game loop" line: at
  least 66 Wait_Recal calls per 100 frames).
- 3D: precompute per-angle projections in ROM (32 KB is plenty) instead of
  rotating vertices at run time. A runtime 8×8 multiply is 11+ cycles, and
  gcc6809's generic multiply is far slower.

## Lesson from the E-SRG dome (2026-10-03)

A rotating geodesic dome (~125 visible edges) was measured three ways:
- Rotating vertices at run time in C: 14 Hz.
- Building a `Draw_VLp` list each frame from per-angle position tables:
  ~400 cycles per edge in gcc6809 C, ~230 in hand-written asm, still 2–3
  frames per redraw. Indexing the tables, the visibility test and appending
  to the list cost more than drawing the line.
- **Precomputing every distinct view as ready `Draw_VLp` lists** (5-fold
  symmetry, so 48 views of 240 rotation steps; ~20 KB ROM): **50 Hz,
  ~20k cycles per frame.** The cost is then ~70 cycles of BIOS overhead
  plus `scale` per vector, and ~200 cycles per re-anchor (`Reset0Ref` and
  an absolute move).

Follow-up (hexagon/pentagon dome, 225 edges, ~145 lines per frame): an
own as6809 list loop with 2-byte entries, the next fetch overlapped with
the beam, and mirror symmetry (x-negated copy of the loop) stores 25 of the
48 views in ~11 KB and leaves ~8k cycles per frame at 50 Hz.

If a scene has few distinct views (fixed camera, symmetric objects, coarse
rotation steps), spend ROM instead of CPU.

## Reproduce

```sh
make test                         # builds tests/vxhost
tools/vecxstat/build.sh           # instrumented core -> build/vecxstat/
tools/vecxstat/survey.sh build/<game>.bin $VIDE/cartridges/BERZERK.BIN
VXDUMP=<cycle> ...                # (env) dump every segment of the first game frame after <cycle>
```
