#!/usr/bin/env bash
# ============================================================================
# gcc6809-driver.sh — drive VIDE's bundled gcc6809 (GCC 4.3.6) outside VIDE.
#
# VIDE ships a working x86-64 `cc1` (m6809 gcc6809) + as6809/aslink/srec2bin
# but no `gcc6809` driver binary on Linux. This script reconstructs that
# driver, replicating the exact PeerC/VIDE build flow (see
# C/PeerC/vectrex/make.bat — the same pipeline on Windows):
#
#   1. cc1        compile each .c  ->  .s   (6809 assembly)
#   2. as6809     assemble  .s     ->  .rel (ASxxxx relocatable)
#   3. aslink     link rels + PeerC CRT/BIOS runtime -> .s19 (rom and ram banks)
#   4. srec2bin   convert s19 -> .bin (ROM bank + .data initial values, which
#                 crt0 copies to RAM $C880 at startup)
#
# This gives the *same compiler that beats CMOC ~2x in code size/speed* on the
# Vectrex (see vectrex.substack.com/p/cmoc-vs-vbcc-vs-gcc6809).
#
# Usage:
#   ./toolchain/gcc6809-driver.sh <src.c|src.s|obj.rel>... -o <out.bin> \
#       [-I<dir>]... [-D<name>[=val]]... [--vide-dir <path>] [--cflags "..."] [-O0|-O1|-O2|-Os|-O3]
#
# .c files go through cc1; .s/.asm files are as6809 (ASxxxx) assembly and are
# assembled directly (same dialect gcc6809 emits — see VIDE's Bouncer sample).
#
# Defaults:
#   --vide-dir  $VIDE_DIR  or  ~/Development/Vide2.5.u64/Vide.u64
#   -O2         (gcc6809's sweet spot; -O0 for debugging)
#   --cflags    (extra, appended)
#
# Requires the PeerC CRT runtime: prebuilt .rel files shipped with VIDE under
# C/PeerC/vectrex/lib/ (crt0.rel, gcc.rel, vec_ram_*.rel, vec_rom_*.rel,
# vec_rum_*.rel) and headers under C/PeerC/vectrex/include/.
# ============================================================================
set -euo pipefail

# --- locate VIDE ------------------------------------------------------------
VIDE_DIR="${VIDE_DIR:-$HOME/Development/Vide2.5.u64/Vide.u64}"
if [ ! -d "$VIDE_DIR/C/Linux64/bin" ]; then
    echo "error: VIDE Linux toolchain not found at $VIDE_DIR" >&2
    echo "set VIDE_DIR=... (path to Vide.u64)" >&2
    exit 1
fi
BIN="$VIDE_DIR/C/Linux64/bin"
PEERC="$VIDE_DIR/C/PeerC/vectrex"

# --- defaults ---------------------------------------------------------------
OPT="-O2"
EXTRA_CFLAGS=""
OUT=""
SRCS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUT="$2"; shift 2 ;;
        --vide-dir) VIDE_DIR="$2"; BIN="$VIDE_DIR/C/Linux64/bin"; PEERC="$VIDE_DIR/C/PeerC/vectrex"; shift 2 ;;
        --cflags) EXTRA_CFLAGS="$2"; shift 2 ;;
        --with-ram) shift ;;   # obsolete: the .data image is always appended
        -O0|-O1|-O2|-Os|-O3) OPT="$1"; shift ;;
        -I*|-D*) EXTRA_CFLAGS="$EXTRA_CFLAGS $1"; shift ;;
        *) SRCS+=("$1"); shift ;;
    esac
done
if [ -z "$OUT" ] || [ ${#SRCS[@]} -eq 0 ]; then
    echo "usage: gcc6809-driver.sh <game.c>... -o <out.bin> [--opt ...] [--cflags ...]" >&2
    exit 2
fi

# --- workspace --------------------------------------------------------------
# Work dir and output must be absolute paths: aslink runs from $PEERC/lib.
# Ensure the output dir exists first (it may not on a fresh checkout).
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
mkdir -p "$(dirname "$OUT")/.gcc6809-work"
WORK="$(cd "$(dirname "$OUT")/.gcc6809-work" && pwd)"
[ -z "${KEEP_WORK:-}" ] && trap 'rm -rf "$WORK"' EXIT

# PeerC/VIDE gcc flags (from BloxorzProjectProperty.xml / make.bat)
GCC_FLAGS="-quiet -W -Wall -Wextra -Wconversion -Wno-return-type -fomit-frame-pointer -fno-toplevel-reorder -mint8 -msoft-reg-count=0 -std=gnu99 -fno-time-report"
CFLAGS="$GCC_FLAGS $EXTRA_CFLAGS -I$PEERC/include $OPT"

PROJ="$(basename "$OUT" .bin | tr . _)"     # aslink cuts names at a "."

echo "== gcc6809 driver (GCC 4.3.6 gcc6809) =="
echo "   cc1:   $BIN/cc1"
echo "   flags: $CFLAGS"

# --- 1. compile PeerC runtime (source/) + game sources -> .s -> .rel --------
# VIDE's make.bat compiles the PeerC runtime FROM SOURCE (C/PeerC/vectrex/source)
# alongside the game. The prebuilt lib/*.rel files are only stubs/externs for
# the fixed-address ROM/RAM symbols; the actual wrapper code (crt0, gcc.c,
# vec_rum_fct_pjc.c etc.) must be compiled. Mirror that here.
# PEERC_SKIP="a.c b.c": runtime files to leave out (the project supplies what
# it needs of them, e.g. its own wrappers for the few BIOS calls it makes:
# aslink links every module given, used or not).
RUNTIME_SRCS=()
for src in "$PEERC/source/"*.c; do
    case " ${PEERC_SKIP:-} " in *" $(basename "$src") "*) continue ;; esac
    RUNTIME_SRCS+=("$src")
done

RELS=()
compile_one() {
    local src="$1"
    local base
    case "$src" in
        *.rel)       # prebuilt ASxxxx object (e.g. VIDE's C/PeerC/vide/lib/*.rel)
            RELS+=("$(cd "$(dirname "$src")" && pwd)/$(basename "$src")")
            return ;;
        *.s|*.asm)   # hand-written as6809 assembly: assemble directly
            base="$(basename "${src%.*}")"
            echo ">> as6809 $(basename "$src")"
            "$BIN/as6809" -x -p -l -o -g "$WORK/$base.rel" "$src"
            RELS+=("$WORK/$base.rel")
            return ;;
    esac
    base="$(basename "$src" .c)"
    echo ">> cc1 $base.c"
    "$BIN/cc1" $CFLAGS -E -o "$WORK/$base.i" "$src"
    "$BIN/cc1" $CFLAGS -o "$WORK/$base.s" "$WORK/$base.i"
    echo ">> as6809 $base.s"
    "$BIN/as6809" -x -p -l -o -g "$WORK/$base.rel" "$WORK/$base.s"
    RELS+=("$WORK/$base.rel")
}

for src in "${RUNTIME_SRCS[@]}"; do
    compile_one "$src"
done
for src in "${SRCS[@]}"; do
    compile_one "$src"
done

# --- 2. link: all compiled rels (+ crt0/gcc libs already included as rels) ---
echo ">> aslink ($((${#RELS[@]})) rels)"
mkdir -p "$WORK"
# Link against gcc6809's libgcc like VIDE's make.bat does: -mint8 code calls
# helpers such as _mulhi3 (16-bit multiply), _divhi3, _ashlhi3 for long math.
LIBDIR="$VIDE_DIR/C/PeerC/lib"
"$BIN/aslink" -n -u -w -s -m \
    -k "$LIBDIR/" -l libgcov.a -l as-libgcc.a -l libgcc.a \
    "$WORK/$PROJ.s19" "${RELS[@]}" > "$WORK/link.log" 2>&1 || true
cat "$WORK/link.log"
# aslink only *warns* about undefined symbols and still writes a ROM that
# jumps into nowhere — treat that as the error it is.
if grep -q 'Undefined Global' "$WORK/link.log"; then
    echo "error: undefined symbols (missing source/.s file or library?):" >&2
    grep -o 'Undefined Global [^ ]*' "$WORK/link.log" | sort -u >&2
    exit 1
fi

# --- 3. convert s19 -> bin ---------------------------------------------------
# aslink -s emits <base>_rom.s19 (cartridge header + code + rodata at $0000)
# and, when the program has initialized globals, <base>_ram.s19 (.data
# initial values at $C880). PeerC's crt0 copies l_.data bytes FROM ROM, at the
# address right after the last text area, INTO $C880 at startup — so the
# cartridge must carry the .data image at exactly that ROM address. Without it
# every initialized global (`int x = 5;`) boots with garbage, on emulators and
# real hardware alike. We therefore always append it (VIDE does the same).
ROM_S19="$WORK/${PROJ}_rom.s19"
MAP="$WORK/$PROJ.map"
"$BIN/srec2bin" -q "$ROM_S19" "$WORK/${PROJ}_rom.bin"
cp "$WORK/${PROJ}_rom.bin" "$OUT"

sym() {  # value of a linker symbol from the aslink map (hex, 0 if absent)
    local v
    v="$(awk -v s="$1" '$2 == s { print $1; exit }' "$MAP")"
    echo "$((16#${v:-0}))"
}
DATA_LEN="$(sym l_.data)"
RAM_S19="$WORK/${PROJ}_ram.s19"
if [ "$DATA_LEN" -gt 0 ]; then
    [ -f "$RAM_S19" ] || { echo "error: .data is $DATA_LEN bytes but $RAM_S19 is missing" >&2; exit 1; }
    # crt0's copy source: s_.text + l_.text + l_.text.hot + l_.text.unlikely
    DATA_ROM=$(( $(sym s_.text) + $(sym l_.text) + $(sym l_.text.hot) + $(sym l_.text.unlikely) ))
    ROM_LEN="$(wc -c < "$OUT")"
    if [ "$ROM_LEN" -gt "$DATA_ROM" ]; then
        echo "error: ROM image ($ROM_LEN bytes) extends past the .data load address $DATA_ROM" >&2
        exit 1
    fi
    "$BIN/srec2bin" -q -o -0xc880 "$RAM_S19" "$WORK/${PROJ}_ram.bin"
    head -c "$((DATA_ROM - ROM_LEN))" /dev/zero >> "$OUT"
    head -c "$DATA_LEN" "$WORK/${PROJ}_ram.bin" >> "$OUT"
    printf '   data: %d bytes at ROM $%04X -> RAM $C880\n' "$DATA_LEN" "$DATA_ROM"
fi
# The BIOS runs the cartridge from the byte after the header's title list
# (its last string's $80, then a 0 byte). That must be where the code starts
# (s_.text): an extra byte there (e.g. a C NUL from a char array one too big)
# runs as an instruction and skips crt0's first one.
TEXT_AT="$(sym s_.text)"
if [ "$TEXT_AT" -ge 2 ]; then
    HDR_END="$(od -An -tx1 -j $((TEXT_AT - 2)) -N 2 "$OUT" | tr -d ' \n')"
    if [ "$HDR_END" != "8000" ]; then
        echo "error: the cartridge header doesn't end (\$80, \$00) right before the code at \$$(printf %04X "$TEXT_AT") (found $HDR_END): check the header's sizes" >&2
        exit 1
    fi
fi
ROM_TOTAL="$(wc -c < "$OUT")"
if [ "$ROM_TOTAL" -gt 32768 ]; then
    echo "error: cartridge is $ROM_TOTAL bytes, over the 32 KB cart space" >&2
    exit 1
fi

echo "== done: $OUT ($(wc -c < "$OUT") bytes) =="
