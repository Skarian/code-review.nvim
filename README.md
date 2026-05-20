# code-review.nvim

`code-review.nvim` adds a plugin-managed Review Mode for Neovim 0.11.

It lets you collect short code review comments while staying in code buffers:

- create project-scoped Reviews;
- attach exact linewise File References from visual selections;
- compose complete Comments manually or by voice;
- see references highlighted in the current buffer;
- detect stale references; and
- open an editable plain-text preview for handoff to an agent or another workflow.

Review Mode is plugin state, not a native Neovim mode.

## Requirements

- Neovim 0.11 or newer.
- [`folke/snacks.nvim`](https://github.com/folke/snacks.nvim) at runtime.
- Node.js 20 or newer for voice.
- Existing Codex ChatGPT auth for voice. If auth is missing or expired, run:

```sh
codex login
```

Voice release qualification targets macOS arm64 and Windows x64. macOS x64 is best effort. Linux and WSL voice support are future work.

## Install

Runtime install should not require a build step:

```lua
{
  "your-org/code-review.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {},
}
```

Optional voice rebuild:

```lua
{
  "your-org/code-review.nvim",
  dependencies = { "folke/snacks.nvim" },
  build = "npm ci --prefix voice && npm run build --prefix voice",
  opts = {},
}
```

Release artifacts include:

- `voice/dist/index.js`
- `voice/package.json`
- `voice/package-lock.json`

## Commands

| Command | Behavior |
| --- | --- |
| `:CodeReview` | Toggle Review Mode. |
| `:CodeReviewHealth` | Open a health report buffer. |
| `:CodeReviewClearData` | Delete the current project store after confirmation. |
| `:checkhealth code-review` | Run health checks. |

## Keymaps

The plugin does not map bare `<leader>r`.

By default, `<leader>r` is only a parent namespace for which-key and child mappings:

| Mapping | Action |
| --- | --- |
| `<leader>ra` | From Visual mode, create a new Comment from the selected lines and open the Comment Editor. |
| `<leader>rr` | From Visual mode, append the selected lines to an existing Comment through the Comment picker. |
| `<leader>rc` | Open the Comment picker for edit, delete, or jump actions. |
| `<leader>rR` | Start Review Mode if needed, then open the Review picker. |
| `<leader>rp` | Open preview. |
| `<leader>rq` | Exit Review Mode. |

The Comment Editor is a stacked floating layout with a read-only status panel, a focusable read-only File References panel, and an editable comment buffer. Initial focus goes to the comment buffer, which contains only the comment body and uses normal Vim editing. `<Tab>` and `<S-Tab>` move between references and the comment body. Normal `<CR>` submits from the comment buffer; `<CR>` on a reference opens Delete / Go to actions; `<leader>d` deletes the whole comment or draft from the comment buffer and deletes the focused File Reference from the references panel. Normal `<leader><Space>` starts, stops, or retries voice dictation. Normal `?` opens Comment Editor help.

New Comments are persisted only after submit succeeds. Submit requires at least one File Reference and non-empty body text. Canceling a new Comment Editor creates nothing.

Configure or disable mappings:

```lua
require("code-review").setup({
  keymaps = {
    prefix = "<leader>r",
    edit_comment = false,
  },
})
```

Disable all default mappings:

```lua
require("code-review").setup({
  keymaps = { enabled = false },
})
```

## Statusline

Use:

```lua
require("code-review").status()
```

It returns `"REVIEW"` while Review Mode is active and `""` otherwise.

## Storage

Review data is stored outside the repository under:

```text
stdpath("data")/code-review.nvim/reviews/<project-root-hash>.json
```

The store contains Review names, Comment bodies, relative file paths, line ranges, selected line snapshots, timestamps, and stale state.

## Voice Privacy

Voice uses existing Codex file-backed ChatGPT auth. The plugin and helper do not:

- perform OAuth;
- refresh tokens;
- use API keys;
- read or write OS keyrings;
- mutate Codex auth files; or
- call Codex CLI.

The helper reads the first available Codex `auth.json`, sends recorded audio to ChatGPT transcription, and returns transcript text to Neovim. Health checks do not open the microphone and do not call `/backend-api/transcribe`.

Automated tests use mock auth, mock audio, and mock HTTP only.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Voice helper missing | Run `:Lazy build code-review.nvim` or `npm ci --prefix voice && npm run build --prefix voice`. |
| Codex auth missing/expired | Run `codex login`. |
| Audio provider unavailable | Rebuild the voice helper and confirm the platform is supported. On macOS, the helper can fall back to `ffmpeg`/AVFoundation if Decibri cannot open the default microphone. |
| Preview blocked | Submit or delete incomplete draft work and update or delete stale File References. |

## Tests

Lua:

```sh
nvim --headless -i NONE -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec { minimal_init = 'tests/minimal_init.lua' }" -c qa
```

All automated gates:

```sh
scripts/validate.sh
NVIM_011=/path/to/nvim-0.11 scripts/validate.sh
```

Final non-interactive gate after `codex login` and Claude CLI login:

```sh
scripts/final-gates.sh
```

Voice:

```sh
npm ci --prefix voice
npm test --prefix voice
npm run typecheck --prefix voice
npm run lint --prefix voice
npm run build --prefix voice
```

Smoke test:

```sh
sh scripts/smoke.sh
NVIM=/path/to/nvim-0.11 sh scripts/smoke.sh
```

Manual voice smoke test after `codex login`:

```sh
scripts/voice-smoke.sh
```

This records one short clip, sends it through the bundled helper, prints the transcript JSON, and deletes the temp audio file.

See [docs/VALIDATION.md](docs/VALIDATION.md) for the full release qualification checklist, including manual voice and external reviewer gates.

External reviewer gate after Claude CLI login:

```sh
scripts/claude-review.sh
```
