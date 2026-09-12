#!/usr/bin/env bash
# Source this file to activate an ESP-IDF toolchain for BUILDING (not
# flashing) an Espressif MCU target.
#
# This project's own build was verified against <TOOLCHAIN_VERSION>
# (e.g. "ESP-IDF v5.5.3") — edit that string in the comment above this
# file's IDF_INSTALL_PATH line to record whichever version you verify a
# clean build against, so a future reader (including future you) knows
# exactly what "it built here" meant. A newer or older ESP-IDF release can
# silently change generated sdkconfig defaults or toolchain flags between
# minor versions — pin and record the version you actually used, don't
# assume "whatever's on the machine" is reproducible.
#
# Usage:
#   source scripts/idf-env.sh
#
# After sourcing, `idf.py`, the target's cross-compiler
# (e.g. xtensa-esp32s3-elf-gcc or riscv32-esp-elf-gcc, depending on
# <SOC_FAMILY>), `cmake`, and `ninja` are on PATH for the rest of this
# shell session. This is a BUILD environment activation only — it does
# not open a serial port, does not run a flashing tool, and does not
# touch a device. Flashing/backup/recovery tooling lives in
# mcu-backup-window.sh and is gated completely separately (see the
# mcu-safe-backup skill) — sourcing this file grants none of that.
#
# On some hosts (macOS in particular, historically) `cmake` and `ninja`
# are "on_request" tools not installed by the default ESP-IDF installer
# and must be fetched once with:
#   $IDF_INSTALL_PATH/tools/idf_tools.py install cmake ninja
# before this script's `export.sh` can put them on PATH. If activation
# succeeds but `idf.py build` still fails to find cmake/ninja, that
# install step — not this script — is almost always the gap.

IDF_INSTALL_PATH="${IDF_PATH:-$HOME/esp/esp-idf}"

if [ ! -f "$IDF_INSTALL_PATH/export.sh" ]; then
  echo "idf-env.sh: could not find $IDF_INSTALL_PATH/export.sh" >&2
  echo "idf-env.sh: expected an ESP-IDF checkout at $IDF_INSTALL_PATH" >&2
  echo "idf-env.sh: override the location with IDF_PATH=/path/to/esp-idf source scripts/idf-env.sh" >&2
  echo "idf-env.sh: if ESP-IDF isn't installed yet, see:" >&2
  echo "idf-env.sh:   https://docs.espressif.com/projects/esp-idf/en/stable/get-started/" >&2
  return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source "$IDF_INSTALL_PATH/export.sh"
