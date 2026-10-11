# ============================================================================
# CMakeLists.txt — CLion entry point for a Vectrex-native game project
#
# CLion does not understand 6809 code (no 6809 toolchain), so this file does
# NOT compile anything itself: it is a thin CMake wrapper that exposes the
# Makefile build as custom targets, and the resulting .bin as an artifact.
#
# In CLion: open this directory as a project. Use the "rom" target (or run
# `make` in the integrated terminal) to build. The ROM can then be run via
# the `run` target or the embedded terminal -> `make run`.
#
# Requires: cmake (CLion bundles one), make, and VIDE (for gcc6809; see
# AGENTS.md).
#
# Note: we call GNU make via its resolved path (MAKE_BIN) instead of the
# `$(MAKE)` substitution, which is Makefiles-generator-only and breaks the
# Ninja generator that CLion uses by default.
# ============================================================================

cmake_minimum_required(VERSION 3.20)
# PROJECT_NAME is the directory name (the new project's name). GAME is the
# default ROM name for the Makefile (override with -DGAME=xxx).
get_filename_component(PROJECT_NAME "${CMAKE_CURRENT_SOURCE_DIR}" NAME)
project(${PROJECT_NAME} C)
set(GAME "e-srg" CACHE STRING "Default Vectrex ROM name for make")

# --- locate GNU make (cross-generator: works for Ninja AND Makefiles) -------
find_program(MAKE_BIN make)
if(NOT MAKE_BIN)
    set(MAKE_BIN "/usr/bin/make")
endif()

# --- the ROM artifact (gcc6809) -----------------------------------------------
set(VECTREX_ROM "${CMAKE_CURRENT_SOURCE_DIR}/build/${GAME}.bin")

# --- custom targets that delegate to make ------------------------------------
add_custom_target(rom
    COMMAND ${MAKE_BIN} -C "${CMAKE_CURRENT_SOURCE_DIR}" GAME=${GAME}
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Building Vectrex-native ROM with gcc6809 (VIDE GCC 4.3.6)"
    VERBATIM
    BYPRODUCTS "${VECTREX_ROM}"
)

add_custom_target(run
    COMMAND ${MAKE_BIN} -C "${CMAKE_CURRENT_SOURCE_DIR}" GAME=${GAME} run
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Run the ROM in RetroArch (vecx core)"
    VERBATIM
)

add_custom_target(test
    COMMAND ${MAKE_BIN} -C "${CMAKE_CURRENT_SOURCE_DIR}" GAME=${GAME} test
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Headless smoke test of the ROM (writes build/<game>.png)"
    VERBATIM
)

# Make the "rom" target the default-ish build alias so CLion's Build button
# delegates to it without us compiling anything on the host.
set(CMAKE_DEFAULT_BUILD_TARGET "rom")

# --- code insight for CLion: an index-only target -----------------------------
# CLion only analyses files that belong to a target. This object library
# lists the C sources with PeerC's headers so navigation, completion and
# error highlighting work; it is EXCLUDE_FROM_ALL and never built (the host
# compiler can't make a 6809 ROM; `rom` does that). The host parser's int
# is 32-bit, not gcc6809's 8-bit (-mint8), so overflow warnings differ.
set(VIDE_DIR "$ENV{HOME}/Development/Vide2.5.u64/Vide.u64" CACHE PATH "VIDE install (Vide.u64)")
file(GLOB VECTREX_C_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/*.c")
add_library(code_insight OBJECT EXCLUDE_FROM_ALL ${VECTREX_C_SOURCES})
target_include_directories(code_insight PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${VIDE_DIR}/C/PeerC/vectrex/include")
set_target_properties(code_insight PROPERTIES C_STANDARD 99 C_EXTENSIONS ON)
