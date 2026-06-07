# code-review.nvim

Collect code-review comments without leaving your buffers, by typing or by voice.

`code-review.nvim` brings a code review workflow into Neovim. Toggle Review Mode, select the lines you want to comment on, and write your feedback by hand or by voice.

A **review** is a named collection of **comments** scoped to one project. Each comment is a note attached to one or more exact line ranges. Reviews are saved locally outside your repo, comments stay anchored to the code they reference (and are flagged when that code changes), and any review can be exported as plain text to hand to an AI agent or paste into a pull request.

- Keep several named reviews per project — one per branch, feature, or review pass.
- Comments anchored to exact line ranges, flagged stale when the code changes.
- Write comments by hand or dictate them by voice.
- Export any review as plain text for agent handoff or copy/paste.

## Requirements

- Neovim 0.11+
- [`folke/snacks.nvim`](https://github.com/folke/snacks.nvim)
- Voice (optional): Node.js 20+ and a Codex ChatGPT login — run `codex login` if you don't have one.

Voice is qualified on macOS. Windows voice support is not release-qualified yet; manual review still works when voice is unavailable.

## Install

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Skarian/code-review.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {},
}
```

Runtime install should not require a build step. To rebuild the bundled voice helper on install:

```lua
{
  "Skarian/code-review.nvim",
  dependencies = { "folke/snacks.nvim" },
  build = "npm ci --prefix voice && npm run build --prefix voice",
  opts = {},
}
```

## Usage

1. Run `:CodeReview` (or `<leader>rR`) in your project, then create a review — just give it a name.
2. In a saved file, visually select some lines and press `<leader>ra`. This opens the Comment Editor with those lines attached.
3. Write your note, or press `<leader><Space>` to dictate it by voice.
4. Leave Insert mode and press `<CR>` to save the comment.
5. Press `<leader>rp` to preview the whole review as plain text, then copy it or hand it off.

## Commands

| Command | Action |
| --- | --- |
| `:CodeReview` | Toggle Review Mode |
| `:CodeReviewHealth` | Open a health report |
| `:CodeReviewClearData` | Delete this project's stored reviews after confirmation |
| `:CodeReviewVoiceDevices` | Choose the microphone used for voice dictation |
| `:checkhealth code-review` | Run health checks |

## Keymaps

All default mappings start with `<leader>r`. Change the prefix, remap any action, or turn one off in [Configuration](#configuration).

| Mapping | Mode | Action |
| --- | --- | --- |
| `<leader>ra` | Visual | New comment from visual selection |
| `<leader>ra` | Normal | Show a visual-selection hint |
| `<leader>rr` | Visual | Append visual selection to an existing comment |
| `<leader>rr` | Normal | Show a visual-selection hint |
| `<leader>rc` | Normal | Comment picker: edit, delete, or jump |
| `<leader>ro` | Normal | Edit the comment under the cursor |
| `<leader>rm` | Normal | Choose the microphone used for voice dictation |
| `<leader>rR` | Normal | Review picker; starts Review Mode if needed |
| `<leader>rp` | Normal | Preview the active review |
| `<leader>rt` | Normal | Toggle Review Mode |

Inside the Comment Editor, `<Tab>` and `<S-Tab>` cycle between References and Comment. `<leader><Space>` starts, cancels startup, stops, or retries voice dictation. `<leader>x` discards a failed voice transcription. `<leader>d` deletes the current draft/comment from the Comment pane, or the focused reference from the References pane. `?` opens editor help.

Disable or remap any action via `setup`; each action also has a `<Plug>(code-review-...)` mapping.

```lua
require("code-review").setup({
  keymaps = { enabled = false }, -- or set an individual action to false
})
```

## Configuration

Defaults:

```lua
require("code-review").setup({
  sidebar = { width = 42, position = "right" },
  keymaps = {
    enabled = true,
    prefix = "<leader>r",
    review_picker = "R",
    add_reference = "a",
    append_reference = "r",
    edit_comment = "c",
    edit_comment_under_cursor = "o",
    microphone = "m",
    preview = "p",
    toggle = "t",
  },
  storage = { dir = nil, debounce_ms = 250 },
  stale = { debounce_ms = 200 },
  voice = {
    enabled = true,
    node_cmd = "node",
    helper_path = nil,
    max_recording_ms = 60000,
    max_audio_bytes = 16 * 1024 * 1024,
    device_cache_ttl_ms = 60000,
    pre_roll_ms = 250,
    min_duration_ms = 900,
    max_transcription_attempts = 3,
    transcription_timeout_ms = 120000,
  },
  health = { network = true },
})
```

Statusline helper: `require("code-review").status()` returns `"REVIEW"` while active, `""` otherwise.

## Storage

Reviews are stored locally under:

```text
stdpath("data")/code-review.nvim/reviews/
```

Stored review data includes comment bodies, file paths, line ranges, selected text snapshots, timestamps, and stale-reference state.

The selected voice microphone is a machine-local preference stored separately under:

```text
stdpath("state")/code-review.nvim/voice-device.json
```

## Voice & privacy

Voice records a short clip and sends it to ChatGPT for transcription, using the Codex login you already have on your machine. The plugin only reads that login; it never modifies it.

Temporary audio is written to disk while you dictate and removed afterward; it is not stored durably. Provider-side retention may apply to transcribed audio.

Use `:CodeReviewVoiceDevices` or `<leader>rm` to choose the microphone used for dictation. The Comment Editor asynchronously prewarms microphone discovery and pre-opens the selected microphone after opening so voice capture can start quickly. The mic may stay open while the editor is open, but audio is not written to disk or transcribed until you press voice; a small in-memory pre-roll protects the first syllable. Without a saved choice, voice capture uses a fresh cached recommendation when available; otherwise the helper lists devices and prefers a likely physical microphone before the system default. The picker labels likely virtual inputs, such as Zoom or loopback devices, but still allows selecting them explicitly.

For manual voice smoke testing, use `CODE_REVIEW_VOICE_AUDIO_DEVICE=<id-or-name> scripts/voice-smoke.sh` to force a specific microphone.

If your Codex login is missing or expired:

```sh
codex login
```

## License

[MIT](LICENSE)
