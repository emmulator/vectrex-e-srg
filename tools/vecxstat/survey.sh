#!/bin/bash
# Measure a ROM's real vector budget in gameplay with the instrumented core.
#   tools/vecxstat/survey.sh ROM.bin [ROM2.bin ...]
# Env: FRAMES (default 2200), SKIP (frames ignored at start, default 1100),
#      HOLDS (vxhost --hold args; default presses 4/1 around frame 700-960 to
#      start GCE-style games, then moves the stick and fires).
# Per ROM it prints, over BIOS Wait_Recal-delimited game frames after SKIP:
#   Hz       game-loop rate (1.5 MHz / median cycles between Wait_Recal calls)
#   lines    median / 90th-percentile lit vectors per game frame, excluding
#            BIOS Print_Str text (counted separately as +text)
#   ink      total lit line length per game frame, in screen widths
#   beam-on  cycles per game frame with the beam lit (and % of the loop)
# and writes build/vecxstat/survey/<name>.png (max of the last 3 frames) so you
# can check the game really reached gameplay. Needs tools/vecxstat/build.sh
# and tests/vxhost (make test builds it).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="$ROOT/build/vecxstat/vecx_libretro.so"
HOST="$ROOT/tests/vxhost"
OUTD="$ROOT/build/vecxstat/survey"
[ -f "$CORE" ] || { echo "run tools/vecxstat/build.sh first" >&2; exit 1; }
[ -x "$HOST" ] || { echo "run make test first (builds tests/vxhost)" >&2; exit 1; }
mkdir -p "$OUTD"
FRAMES=${FRAMES:-2200}; SKIP=${SKIP:-1100}
HOLDS=${HOLDS:---hold 4@700-706 --hold 1@760-766 --hold 4@820-826 --hold 1@900-906 --hold 4@960-966 --hold right@1200-1400 --hold up@1500-1700 --hold 1@1300-1310 --hold 1@1800-1810}
for rom in "$@"; do
    name=$(basename "$rom"); name=${name%.*}
    out="$OUTD/$name"
    # shellcheck disable=SC2086
    VXSTATS=1 "$HOST" "$CORE" "$rom" --frames "$FRAMES" --persist 3 --ppm "$out.ppm" $HOLDS 2>"$out.log" >/dev/null
    python3 - "$out.log" "$SKIP" "$name" <<'PY'
import sys, statistics as st
log, skip, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
# GF <total_cycles> <frame_cycles> <lines> <dots> <beam_cycles> <text_segs> <ink_units>
rows = [list(map(int, l.split()[1:6])) + [int(l.split()[6]), float(l.split()[7])]
        for l in open(log) if l.startswith("GF ")]
rows = [r for r in rows if r[0] > skip * 30000 and r[1] > 3000]
if len(rows) < 5:
    print(f"{name:20s} no BIOS Wait_Recal frames (custom sync?)"); sys.exit()
col = lambda i: [r[i] for r in rows]
p90 = lambda v: sorted(v)[int(.9 * len(v))]
cyc, lines, beam, txt = col(1), col(2), col(4), col(5)
ink = [r[6] / 43000 for r in rows]          # vecx ALG_MAX_X = 43000 units across
print(f"{name:20s} {1.5e6 / st.median(cyc):5.1f}Hz  lines med {st.median(lines):4.0f} p90 {p90(lines):4d}"
      f" (+text {st.median(txt):3.0f})  ink {st.median(ink):5.1f} p90 {p90(ink):5.1f} screens"
      f"  beam-on {st.median(beam):6.0f} cyc ({100 * st.median(beam) / st.median(cyc):2.0f}%)")
PY
    python3 -c "from PIL import Image; Image.open('$out.ppm').save('$out.png')" 2>/dev/null || true
done
