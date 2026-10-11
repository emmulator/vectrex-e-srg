# ============================================================================
# Makefile — build a Vectrex-native cartridge ROM (.bin)
#
# Toolchain: gcc6809 (VIDE's bundled GCC 4.3.6 + PeerC runtime),
# driven by toolchain/gcc6809-driver.sh — the smallest/fastest 6809 code of
# the available C compilers (see AGENTS.md).
#
# ROMs are named <GAME>-<version><build>.bin; the version is GAME_VERSION in
# src/e-srg.c, the build letter (also shown on the boot screen) is the preset:
#   make            build build/<GAME>-<ver>v.bin from src/*.c, *.s, *.rel: a typical Vectrex
#   make emu        build build/<GAME>-<ver>e.bin: for the emulator (-DDOME_NO_TAIL)
#   make mine       build build/<GAME>-<ver>m.bin: preset for one particular Vectrex (TAIL_MINE: set your own)
#   make jukebox    build build/jukebox.bin (plays the BIOS tunes); jukebox-run
#   make mame / vide / esde   play the emulator ROM in MAME / VIDE / via ES-DE
#   make test       headless smoke test of the emulator ROM (writes .png)
#   make run        build and run the emulator ROM in RetroArch (vecx core)
#   make clean      remove build artifacts
# ============================================================================

GAME     ?= e-srg
SRCDIR   := src
BUILDDIR := build
# -Os: -O2 no longer fits, and -Os measured no slower in play (2026-10-11)
OPT      ?= -Os

# --- gcc6809 -------------------------------------------------------------------
VIDE_DIR ?= $(HOME)/Development/Vide2.5.u64/Vide.u64
GCC_SRCS := $(sort $(wildcard $(SRCDIR)/*.c $(SRCDIR)/*.s $(SRCDIR)/*.rel))
GCC_DEPS := $(GCC_SRCS) $(wildcard $(SRCDIR)/*.h) toolchain/gcc6809-driver.sh
VERSION  := $(shell sed -n 's/^\#define GAME_VERSION "\([^"]*\)".*/\1/p' $(SRCDIR)/e-srg.c)
TARGET   := $(BUILDDIR)/$(GAME)-$(VERSION)v.bin
# extra driver flags, e.g. GCC_FLAGS="-I$(VIDE_DIR)/C/PeerC/vide/include"
GCC_FLAGS ?=
# PeerC runtime files left out: src/bios.s has the few BIOS wrappers we call
# (PeerC's file links all ~150, ~640 bytes); nothing needs gcc.c's memcpy etc.
PEERC_SKIP ?= vec_rum_fct_pjc.c gcc.c

.PHONY: all emu mine test run clean jukebox jukebox-run mame vide esde

all: $(TARGET)

# build/<GAME>-<ver>v.bin: for a typical Vectrex (gen_dome.py TAIL_DEFAULT; players
# can trim it in game: hold button 4, stick left/right).
$(TARGET): $(GCC_DEPS) | $(BUILDDIR)
	VIDE_DIR=$(VIDE_DIR) PEERC_SKIP="$(PEERC_SKIP)" ./toolchain/gcc6809-driver.sh $(GCC_SRCS) $(GCC_FLAGS) $(OPT) -o $@

# build/<GAME>-<ver>e.bin: for vecx (no ramp tail: -DDOME_NO_TAIL), built by
# make run / make test. GCC_FLAGS apply to both.
EMU_TARGET := $(BUILDDIR)/$(GAME)-$(VERSION)e.bin
EMU_FLAGS  ?= -DDOME_NO_TAIL
emu: $(EMU_TARGET)
$(EMU_TARGET): $(GCC_DEPS) | $(BUILDDIR)
	VIDE_DIR=$(VIDE_DIR) PEERC_SKIP="$(PEERC_SKIP)" ./toolchain/gcc6809-driver.sh $(GCC_SRCS) $(EMU_FLAGS) $(GCC_FLAGS) $(OPT) -o $@

# build/<GAME>-<ver>m.bin: preset for one particular console (TAIL_MINE in
# tools/gen_dome.py: put your own console's calibration there).
MINE_TARGET := $(BUILDDIR)/$(GAME)-$(VERSION)m.bin
mine: $(MINE_TARGET)
$(MINE_TARGET): $(GCC_DEPS) | $(BUILDDIR)
	VIDE_DIR=$(VIDE_DIR) PEERC_SKIP="$(PEERC_SKIP)" ./toolchain/gcc6809-driver.sh $(GCC_SRCS) -DDOME_MINE $(GCC_FLAGS) $(OPT) -o $@

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# --- run / test --------------------------------------------------------------
# The vecx core has the Vectrex BIOS embedded (STANDARD_BIOS), so no
# external exec_rom.bin is required.
CORE   := $(HOME)/.var/app/org.libretro.RetroArch/config/retroarch/cores/vecx_libretro.so
VXHOST := tests/vxhost
# extra vxhost options for make test, e.g. TEST_ARGS="--frames 900 --hold 1@650-660"
TEST_ARGS ?=

run: $(EMU_TARGET)
	flatpak run org.libretro.RetroArch -L $(CORE) $(abspath $(EMU_TARGET))

test: $(EMU_TARGET) $(VXHOST)
	VECX_CORE=$(CORE) ./tests/smoke.sh $(EMU_TARGET) $(TEST_ARGS)

# headless libretro host for the execution test (libretro.h is vendored)
$(VXHOST): tests/vxhost.c tests/libretro.h
	gcc -O2 -o $@ $< -ldl -I tests

# Other emulators (all play the emulator ROM):
#   make mame   MAME (flatpak); needs vectrex.zip (exec_rom.bin) in MAME_ROMS
#   make vide   VIDE's emulator (tools/vide-run.sh)
#   make esde   copy it into ES-DE's Vectrex folder as E-SRG.bin
MAME_ROMS ?= $(HOME)/ROMs/mame
ESDE_VECTREX ?= $(HOME)/ROMs/vectrex
mame: $(EMU_TARGET)
	flatpak run org.mamedev.MAME -rompath $(MAME_ROMS) -window -skip_gameinfo vectrex -cart $(abspath $(EMU_TARGET))
vide: $(EMU_TARGET)
	VIDE_DIR=$(VIDE_DIR) ./tools/vide-run.sh $(EMU_TARGET)
esde: $(EMU_TARGET)
	cp $(EMU_TARGET) $(ESDE_VECTREX)/E-SRG.bin

# build/jukebox.bin: plays the BIOS's 14 tunes (tools/jukebox/), to choose
# one for the cartridge header. Uses PeerC's full wrapper set (no PEERC_SKIP).
JUKEBOX := $(BUILDDIR)/jukebox.bin
jukebox: $(JUKEBOX)
$(JUKEBOX): tools/jukebox/jukebox.c toolchain/gcc6809-driver.sh | $(BUILDDIR)
	VIDE_DIR=$(VIDE_DIR) ./toolchain/gcc6809-driver.sh tools/jukebox/jukebox.c $(OPT) -o $@
jukebox-run: $(JUKEBOX)
	flatpak run org.libretro.RetroArch -L $(CORE) $(abspath $(JUKEBOX))

clean:
	rm -rf $(BUILDDIR)
