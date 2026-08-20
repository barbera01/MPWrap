#!/usr/bin/env bash
# Runs the mpwrap.nvim test suite headlessly and exits non-zero on failure.
# No physical MicroPython device required - see tests/panel_spec.lua.
set -euo pipefail

cd "$(dirname "$0")/.."

nvim --headless --noplugin -u NONE -c "luafile tests/run.lua"
