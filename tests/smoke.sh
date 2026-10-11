#!/usr/bin/env bash
# ============================================================================
# smoke.sh — headless smoke test of a Vectrex cartridge ROM (used by make test)
#
#   tests/smoke.sh <rom.bin> [vxhost options]      e.g. --frames 900 --hold 1@650-660
#
# Checks, in order (any failure exits non-zero):
#   1. structural   ROM starts with the "g GCE" cartridge signature, fits 32 KB
#   2. execution    boots the ROM in the vecx core (embedded BIOS) via
#                   tests/vxhost and requires that CART code actually runs —
#                   the stock BIOS intro alone lasts ~512 frames, carts take
#                   over around frame 638 (later with a longer boot tune: 714 with Star
#                   Trek), so the default run is 900 frames (--frames overrides)
#   3. picture      the last 10 frames (max per pixel) are written to <rom>.png;
#                   it must not be blank — open the PNG to see what was drawn
#   (also printed: the game-loop rate — "OVER BUDGET" means one loop iteration
#   takes longer than the 30,000-cycle frame)
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="${VECX_CORE:-$HOME/.var/app/org.libretro.RetroArch/config/retroarch/cores/vecx_libretro.so}"
VXHOST="$HERE/vxhost"

[ $# -ge 1 ] || { sed -n 4,6p "$0"; exit 2; }
ROM="$(realpath "$1")"; shift
PNG="${ROM%.bin}.png"

python3 - "$ROM" <<'EOF'
import sys
d = open(sys.argv[1], "rb").read()
ok = d[:5] == b"g GCE" and len(d) <= 32768
print(f"rom: {len(d)} bytes, signature {d[:5]!r}")
sys.exit(0 if ok else "FAIL: not a valid Vectrex cartridge image")
EOF

[ -f "$CORE" ] || { echo "FAIL: vecx core not found at $CORE (set VECX_CORE)" >&2; exit 1; }
[ -x "$VXHOST" ] || { echo "FAIL: $VXHOST not built (make tests/vxhost)" >&2; exit 1; }

PPM="${ROM%.bin}.ppm"
rc=0
# --persist 10: the PNG is the brightest pixel over the last 10 frames, so a
# game loop that overruns its frame still shows everything it draws.
"$VXHOST" "$CORE" "$ROM" --frames 900 --ppm "$PPM" --persist 10 "$@" || rc=$?

python3 - "$PPM" "$PNG" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1])
lit = sum(1 for v in im.convert("L").tobytes() if v > 40)
im.save(sys.argv[2], format="PNG")
print(f"picture (last 10 frames) -> {sys.argv[2]} ({lit} lit pixels)")
sys.exit(0 if lit else "FAIL: last frame is blank (nothing drawn, or drawn off-screen)")
EOF
rm -f "$PPM"
[ "$rc" -eq 0 ] || { echo "FAIL: cart code never ran (see the PNG)" >&2; exit 1; }
echo "PASS"
