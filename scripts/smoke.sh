#!/usr/bin/env sh
set -eu

NVIM_BIN="${NVIM:-nvim}"
exec "$NVIM_BIN" --headless -i NONE -u NONE -c "lua dofile('scripts/smoke.lua')" -c qa
