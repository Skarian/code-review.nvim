#!/usr/bin/env sh
set -eu

NVIM_BIN="${NVIM:-nvim}"

"$NVIM_BIN" --headless -i NONE -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec { minimal_init = 'tests/minimal_init.lua' }" -c qa
npm ci --prefix voice
npm test --prefix voice
npm run typecheck --prefix voice
npm run lint --prefix voice
npm run build --prefix voice
sh scripts/smoke.sh

if [ -n "${NVIM_011:-}" ]; then
  NVIM="$NVIM_011" sh scripts/smoke.sh
fi
