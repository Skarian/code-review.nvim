# Validation

This file records the release qualification gates for `code-review.nvim`.

## Automated Gates

Run from the repository root:

```sh
scripts/validate.sh
NVIM_011=/path/to/nvim-0.11 scripts/validate.sh
```

To run the non-interactive final gate after `codex login` and Claude CLI login:

```sh
scripts/final-gates.sh
```

Or run each gate individually:

```sh
nvim --headless -i NONE -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec { minimal_init = 'tests/minimal_init.lua' }" -c qa
npm ci --prefix voice
npm test --prefix voice
npm run typecheck --prefix voice
npm run lint --prefix voice
npm run build --prefix voice
sh scripts/smoke.sh
NVIM=/path/to/nvim-0.11 sh scripts/smoke.sh
```

Expected:

- Lua specs pass.
- Voice helper tests pass without real credentials, microphone, or network.
- TypeScript typecheck runs real `tsc --noEmit`.
- Voice helper build creates `voice/dist/index.js`.
- Smoke passes on Neovim 0.11 or newer.

## Manual Voice Gate

Requires fresh Codex ChatGPT auth and microphone access:

```sh
codex login
node voice/dist/index.js health
scripts/voice-smoke.sh
```

Expected:

- Health reports usable Codex ChatGPT auth.
- Health does not open the microphone.
- The smoke script records one short clip, transcribes it, prints transcript JSON, and deletes the temp audio file.
- Missing or expired auth tells the user to run `codex login`.

## External Reviewer Gate

Requires a logged-in Claude CLI:

```sh
scripts/claude-review.sh
```

Expected:

- Claude CLI produces an implementation review.
- Any concrete blocker is either fixed or explicitly documented as out of MVP scope.

## Current Known External Blockers

As of 2026-05-18:

- Live voice qualification passed with `scripts/voice-smoke.sh`.
- A fresh post-fix `scripts/claude-review.sh` rerun reports `You've hit your org's monthly usage limit`.
