#!/bin/bash
# vide-run.sh ROM: play a ROM in VIDE's emulator (vecxi). The bundled VIDE
# 2.5 (2019) takes options on its command line, one per argument as
# -xx=value or -xx+/-xx- (other forms are silently ignored): -bi=<file>
# loads a binary and starts vecxi, -ex+ quits VIDE when vecxi closes. (Newer
# VIDE source reads them from <VIDE_HOME>/vide.cli instead.)
set -eu
rom="$(realpath "${1:?usage: vide-run.sh ROM}")"
VIDE_HOME="${VIDE_DIR:-$HOME/Development/Vide2.5.u64/Vide.u64}"
export VIDE_HOME
cd "$VIDE_HOME"
exec ./Vide.app/VideC "-bi=$rom" "-ex+"
