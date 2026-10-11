#!/bin/bash
# Build an instrumented vecx libretro core that reports per-game-frame vector
# statistics on stderr (VXSTATS=1), used by tools/vecxstat/survey.sh.
# Source: malbanGit/libretro-vecx at a pinned commit, plus vecxstat.patch
# (which also fixes two stray tokens at that commit that break the build).
# Output: build/vecxstat/vecx_libretro.so   (CPU-only build, HAS_GPU=0)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/build/vecxstat"
REV=fc2b209e319b50b51ea35871f644fda8f0825200
LOCAL="${VECX_SRC:-$HOME/Development/github/malbanGit/libretro-vecx}"
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
if [ -d "$LOCAL/.git" ]; then
    git clone -q "$LOCAL" "$OUT"
else
    git clone -q https://github.com/malbanGit/libretro-vecx.git "$OUT"
fi
git -C "$OUT" checkout -q "$REV"
patch -s -d "$OUT" -p1 < "$HERE/vecxstat.patch"
make -s -C "$OUT" -j"$(nproc)" HAS_GPU=0 >"$OUT.log" 2>&1 || { tail -30 "$OUT.log"; exit 1; }
echo "built $OUT/vecx_libretro.so"
