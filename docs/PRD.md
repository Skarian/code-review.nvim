# PRD: code-review.nvim

## Summary

`code-review.nvim` is a Neovim 0.11 plugin for collecting code review comments without leaving code buffers.

The user toggles a plugin-managed Review Mode with:

```vim
:CodeReview
```

Review Mode is not a Neovim core mode. It is plugin-owned state with its own sidebar, statusline signal, keymaps, storage lifecycle, voice flow, preview buffer, and health checks.

The MVP supports:

- project-scoped Reviews that persist locally;
- Comments with one body and one or more exact line references;
- linewise visual selection capture;
- stacked floating Comment Editor flow;
- voice transcription through a bundled Node/TypeScript helper;
- stale-reference detection;
- current-buffer highlights; and
- an editable plain-text preview for agent handoff or manual copy/paste.

The workflow is code-buffer-first. The sidebar is a persistent overview and state surface, not the primary CRUD UI.

## Goals

1. Let reviewers collect review comments while navigating source files normally.
2. Keep review data durable, local, project-scoped, and out of the repository.
3. Preserve exact source references. If referenced code changes, mark the reference stale instead of guessing.
4. Make voice transcription the preferred body-entry path while keeping manual editing reliable.
5. Generate a plain, editable preview that can be handed to an agent or copied into another workflow.

## Non-goals for MVP

- Native Neovim mode integration.
- Mouse-driven sidebar controls.
- GitHub, GitLab, pull request, or issue tracker API integration.
- Submitting comments directly to agents or external services.
- Local/offline transcription.
- API-key auth, plugin OAuth, token refresh, or OS keyring integration.
- Auto-shifting or repairing stale references.
- Cross-project Reviews or File References.
- Rich Markdown export, comment numbering, code snippets, or automatic clipboard copy.
- Realtime voice transcription.
- Linux/WSL voice release qualification.
- Strong concurrent-session locking.

## Product decisions

| Decision | Requirement |
| --- | --- |
| Review Mode is plugin-managed | `:CodeReview` toggles plugin state; no native Neovim mode is added. |
| Code buffers stay primary | Most actions run from normal saved buffers inside the locked project root. |
| Sidebar is read-only | It shows Review state, Comments, references, and legend. It does not become a CRUD app. |
| References are exact | File References store path, line range, and selected line snapshot. Changed content becomes stale. |
| Manual edit is first-class | Voice can be unavailable; users can still create and preview reviews manually. |
| Voice auth is narrow | Read existing Codex ChatGPT file auth only. Do not mutate auth files or offer alternate credential flows. |
| Preview is non-durable | Preview edits never modify stored Review data. |

## Vocabulary

- **Review**: a named, durable collection of Comments scoped to one project root.
- **Comment**: one review note. It has one body and one or more File References. Persisted Comments are complete by construction: at least one File Reference and non-empty body text after trimming whitespace.
- **File Reference**: an exact linewise reference to one saved file inside the locked project root. It stores relative path, one-based inclusive start/end lines, and the selected line snapshot.
- **Sidebar**: a persistent read-only right split shown while Review Mode is active.
- **Comment Editor**: a stacked floating layout for creating or editing complete Comments. It owns draft body text, draft references, validation, and local voice state until submit or cancel.
- **Preview**: an editable unnamed normal buffer opened in the current window. It is regenerated from Review data and is never persisted by the plugin.
- **Stale File Reference**: a File Reference whose file is missing, range is invalid for current contents, current lines differ from the snapshot, or the reference cannot be checked safely.

## Runtime requirements

- Neovim `>= 0.11`.
- Lua plugin code.
- `folke/snacks.nvim` as runtime dependency.
- Bundled voice helper compiled to `voice/dist/index.js`.
- Node.js `>= 20.x` for voice helper execution.

Development/test requirements:

- `nvim-lua/plenary.nvim` for Lua tests.
- Node package tooling under `voice/`.
- `voice/package-lock.json` committed.

The plugin must never run `npm install`, `npm ci`, or any package manager command automatically at runtime.

## Install and packaging

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

Release artifacts must include:

- `voice/dist/index.js`
- `voice/package.json`
- `voice/package-lock.json`

Manual Review Mode must work when the helper is missing or voice is unavailable. The sidebar should still show the voice action as unavailable when configured. Pressing it should notify with a concrete fix, for example:

```text
Voice helper missing: run :Lazy build code-review.nvim
```

Voice release qualification targets macOS arm64 and Windows x64. macOS x64 is best effort if the selected audio provider ships compatible binaries. Linux and WSL are future work.

## Public API and commands

### Lua API

```lua
require("code-review").setup(opts)
require("code-review").toggle()
require("code-review").status()
require("code-review").is_active()
```

`status()` returns `"REVIEW"` while Review Mode is active and `""` otherwise.

`is_active()` returns a boolean.

### Commands

| Command | Behavior |
| --- | --- |
| `:CodeReview` | Toggle Review Mode. |
| `:CodeReviewHealth` | Show the same checks exposed by `:checkhealth code-review`. |
| `:CodeReviewClearData` | Delete the current project store after confirmation. |
| `:checkhealth code-review` | Run health checks. |

If `:CodeReviewClearData` runs while Review Mode is active, Review Mode exits first, clears UI/transient state, and then deletes the current project store after confirmation. It must not delete corrupt backups.

The plugin ships highlight groups users can style. README may show statusline integrations, but the plugin must not depend on any statusline plugin.

## Configuration

Default configuration:

```lua
{
  sidebar = {
    width = 42,
    position = "right",
  },
  keymaps = {
    enabled = true,
    prefix = "<leader>r",
    review_picker = "R",
    add_reference = "a",
    append_reference = "r",
    edit_comment = "c",
    preview = "p",
    toggle = "t",
  },
  storage = {
    dir = nil,
    debounce_ms = 250,
  },
  stale = {
    debounce_ms = 200,
  },
  voice = {
    enabled = true,
    node_cmd = "node",
    helper_path = nil,
    max_recording_ms = 60000,
    max_audio_bytes = 16 * 1024 * 1024,
    min_duration_ms = 900,
    max_transcription_attempts = 3,
    transcription_timeout_ms = 120000,
  },
  health = {
    network = true,
  },
}
```

Rules:

- All action mappings are configurable.
- `keymaps.enabled = false` creates no default action mappings.
- Setting one `keymaps.<action>` value to `false` disables only that default mapping.
- Each non-false action value is appended to `keymaps.prefix`.
- The plugin does not create a default mapping for bare `:CodeReview`.
- `keymaps.prefix` is a parent namespace only. It is not mapped to an action by itself.
- Voice credential strategy is not configurable in MVP.

## Keymaps

The command entrypoint remains `:CodeReview`.

There is no default bare keymap for `:CodeReview`. Users may still call the command directly or create their own mapping, but the built-in mapping model uses a parent namespace such as `<leader>r` and only maps child actions.

The plugin exposes `<Plug>(code-review-...)` mappings for all actions.

Default action mappings:

| Mapping | Mode | Action |
| --- | --- | --- |
| `<leader>ra` | Visual | Create a new Comment from the selected lines and open the Comment Editor. |
| `<leader>rr` | Visual | Append selected lines to an existing Comment through the Comment picker. |
| `<leader>rc` | Normal | Open the Comment picker for edit, delete, or jump actions. |
| `<leader>rR` | Normal | Open Review picker. If Review Mode is inactive, start it first. |
| `<leader>rp` | Normal | Open preview. |
| `<leader>rt` | Normal | Toggle Review Mode. |

Rules:

- No bare single-key mappings that shadow normal editing keys.
- Default mappings are prefixed action mappings under `keymaps.prefix`.
- `review_picker` is the key-driven Review picker action. If inactive, it performs the same startup work as `:CodeReview` and then opens the Review picker. If active, it opens the Review picker subject to state guards.
- Actions other than `review_picker` require Review Mode to be active and notify without side effects when inactive.
- Default mappings must not make `<leader>r` itself wait for a shorter conflicting mapping, because `<leader>r` is not mapped by the plugin.
- Default child mappings are installed at setup time so `<leader>rR` can start Review Mode from inactive state.
- Do not map terminal, help, prompt, quickfix, sidebar, preview, or composer buffers except for buffer-specific UI behavior.
- Visual add-reference must capture visual marks before leaving visual mode.
- Optional `which-key.nvim` registration must be idempotent and must not warn when absent.
- Optional `which-key.nvim` registration uses `keymaps.prefix` as the `Code Review` group and registers child action labels below it.

## Review Mode lifecycle

States:

- `inactive`
- `review_picker`
- `comment_list`
- `composer`
- `recording`
- `transcribing`
- `voice_error_pending`
- `preview`

Core transitions:

- `:CodeReview` from `inactive` detects and locks the project root, loads the project store, and enters `comment_list` if an active Review exists. Otherwise it opens the Review picker.
- `:CodeReview` from any active state exits Review Mode.
- Visual add-reference from `comment_list` opens a new Comment Editor with the selected lines as draft reference.
- Visual append-reference from `comment_list` captures the selected lines and opens the Comment picker. Selecting a Comment appends the captured reference to that Comment.
- Normal edit-comment from `comment_list` opens the Comment picker. Selecting a Comment opens the Comment Editor for editing that persisted Comment.
- Comment Editor submit validates at least one draft reference and non-empty trimmed body, then creates or updates one persisted Comment.
- Comment Editor cancel discards draft state. Canceling a new Comment Editor creates nothing.
- Voice start/stop from the Comment Editor transitions through `recording`, `transcribing`, and either back to `composer` or to `voice_error_pending`.
- Opening Preview enters `preview` if validation passes.
- Closing Preview restores the previous Review Mode state if Review Mode is still active.
- Quit from any active state stops helper processes, discards transient composer/audio/preview state, closes UI, persists durable data, and returns to `inactive`.

Guards:

- Review picker opens only from `comment_list`.
- Switching Reviews from `composer`, `recording`, `transcribing`, or `voice_error_pending` is blocked.
- Preview is blocked while a composer is open, recording, transcribing, or voice error is pending.
- While the Comment Editor is open, code-buffer Review Mode actions notify: `Submit or cancel the Comment Editor first.`
- While voice error is pending, only retry, discard, cancel composer, and quit are allowed.
- During recording and transcribing, add-reference, edit-comment, Review switching, and preview are blocked.

## Project root and paths

Root detection on `:CodeReview`:

1. If the current buffer is a normal saved file buffer, start from that file.
2. Otherwise start from the current working directory.
3. Use `vim.fs.root(source, { ".git" })`.
4. Fallback to current working directory.

The detected root is locked for the Review Mode session. It does not change when `cwd` changes.

File References can be created only from saved, unmodified normal file buffers inside the locked root. If the buffer is modified, unsaved, or outside the root, add-reference notifies and does nothing.

Persisted paths:

- are relative to the locked root;
- always use `/`, including on Windows;
- must never be absolute; and
- use case-insensitive absolute comparisons on Windows.

Symlink behavior follows Neovim/editor-resolved paths for MVP. There is no custom symlink policy beyond outside-root rejection.

## Storage

Reviews are stored as project-scoped JSON under Neovim’s data directory.

Default path:

```text
stdpath("data")/code-review.nvim/reviews/<sha256(canonical_project_root)>.json
```

Canonical root:

- Prefer `vim.uv.fs_realpath()`.
- Fallback to absolute normalized editor path.
- Hash with SHA-256.

Storage rules:

- Top-level `schema_version` is required.
- Review, Comment, and File Reference IDs are random UUID-like strings with prefixes.
- Timestamps are ISO 8601 UTC.
- Writes go to a temporary file in the same directory and then atomically rename over the target.
- Persistence is debounced after changes.
- Exit and `VimLeavePre` force a write.
- Concurrent sessions are last-write-wins for MVP.
- Strong lock-file protection is future work.

Corrupt store behavior:

- Corrupt JSON is renamed to `<project_root_hash>.corrupt-YYYYMMDDTHHMMSSZ.json` in the same storage directory.
- After backup, create a fresh store.
- Notify with backup path and original filename.
- Unsupported future `schema_version` is not renamed or overwritten. Notify and fail safe.

Schema v1:

```json
{
  "schema_version": 1,
  "project_root": "/canonical/root",
  "project_root_hash": "sha256...",
  "last_active_review_id": "review_...",
  "reviews": [
    {
      "id": "review_...",
      "name": "Auth refactor",
      "created_at": "2026-05-18T12:00:00Z",
      "updated_at": "2026-05-18T12:05:00Z",
      "comments": [
        {
          "id": "comment_...",
          "body": "This skips validation.",
          "created_at": "2026-05-18T12:01:00Z",
          "updated_at": "2026-05-18T12:05:00Z",
          "file_references": [
            {
              "id": "ref_...",
              "relative_path": "lua/auth.lua",
              "start_line": 42,
              "end_line": 51,
              "selected_lines_snapshot": ["..."],
              "stale_state": "fresh",
              "stale_reason": null,
              "created_at": "2026-05-18T12:01:00Z",
              "updated_at": "2026-05-18T12:01:00Z"
            }
          ]
        }
      ]
    }
  ]
}
```

Validation:

- Missing, non-numeric, or invalid `schema_version` is corrupt.
- Future schema versions fail safe and must not be overwritten.
- Unknown extra fields are ignored.
- Missing or invalid required fields are corrupt.
- Duplicate Review, Comment, or File Reference IDs are corrupt.
- Invalid timestamps are corrupt.
- Stored `project_root_hash` must match the canonical root hash. Mismatch fails safe without overwrite.
- Dangling `last_active_review_id` is cleared and Review Mode opens the picker.
- Absolute persisted File Reference paths are corrupt.
- Non-integer line numbers, `start_line < 1`, or `end_line < start_line` are corrupt.
- Invalid `selected_lines_snapshot` values are corrupt.
- Unknown `stale_state` or `stale_reason` values normalize to `stale`/`unknown` if the rest of the File Reference is structurally valid.
- Later missing, changed, unreadable, or out-of-bounds referenced content is stale, not corrupt.

## Reviews and Comments

A project can have multiple Reviews. Exactly one Review is active at a time.

When Review Mode starts:

- Reopen `last_active_review_id` if valid.
- Otherwise show the Review picker.
- Canceling the picker with no active Review exits Review Mode.
- Canceling with an active Review restores the previous state.

Review picker supports selection, creation, and deletion.

Review creation requires only a name. The new Review becomes active and enters `comment_list`.

Review deletion uses simple confirmation. Deleting the active Review selects the next newest Review if one exists. Deleting the only Review leaves Review Mode active only if the user creates or selects another Review; otherwise cancel exits Review Mode.

Sorting:

- Review picker: `updated_at` descending.
- Sidebar Comments: `updated_at` descending.
- Preview Comments: `created_at` ascending.
- File References inside a Comment: insertion order.

Comment rules:

- Comments have invisible IDs and no user-facing names.
- A complete Comment has at least one File Reference and non-empty trimmed body.
- Normal creation and editing flows persist only complete Comments.
- Preview validation still treats incomplete persisted Comments as invalid defensive data and blocks preview.
- Users cannot create or edit another Comment while a composer is open.
- Deleting a Comment removes it from the active Review without selecting another Comment.

## File References

A File Reference stores:

- `relative_path`
- `start_line`
- `end_line`
- `selected_lines_snapshot`
- `stale_state`
- `stale_reason`

Creation rules:

- Created from a visual selection only.
- Selections are promoted to full-line ranges.
- Ranges are one-based and inclusive.
- Charwise and blockwise precision are non-goals.
- Creation requires a saved, unmodified normal file buffer inside the locked root.
- `<leader>ra` creates a new Comment Editor with the selected range as its first draft reference.
- `<leader>rr` opens a Comment picker and appends the selected range to the chosen persisted Comment.
- The snapshot is captured from buffer lines at creation time.

Stale repair is manual:

1. Open the Comment picker.
2. Edit the stale Comment in the composer.
3. Delete the stale draft File Reference from the composer.
4. Select the corrected line range.
5. Append or recreate the File Reference.

MVP does not auto-shift, update, or repair references.

## Staleness

A File Reference is stale if:

- the referenced file is missing;
- the stored range is beyond the current line count;
- current lines do not exactly match `selected_lines_snapshot`; or
- the reference cannot be checked safely because of I/O, binary, or encoding errors.

Comparison rules:

- Compare exact line arrays, including whitespace.
- Use Neovim line semantics.
- Line-ending-only differences are ignored when Neovim normalizes both sources to the same line array.

Source selection:

- If the referenced file is loaded in a normal unmodified buffer, compare against that buffer.
- Otherwise compare against disk contents.

Reasons:

| Reason | Meaning |
| --- | --- |
| `missing_file` | The referenced file is gone. |
| `range_out_of_bounds` | Stored range exceeds current line count. |
| `content_mismatch` | Current lines differ from the stored snapshot. |
| `unknown` | File could not be checked safely. |

Stale references persist, are visually flagged, and block preview.

Autocmd triggers:

- `BufEnter`: check relevant file and refresh highlights.
- `TextChanged` / `TextChangedI`: debounce check for referenced file.
- `BufWritePost`: immediate check.
- `BufDelete` / `BufUnload`: clear extmarks for that buffer.
- `DirChanged`: keep locked root and optionally notify once.
- `VimLeavePre`: force persistence and stop voice helper.

## Highlights

While Review Mode is active, the current buffer highlights all File References in the active Review that point to the current file.

Requirements:

- Use extmarks with line highlights.
- Distinct highlight for stale references.
- No virtual text for MVP.
- Extmarks are display-only. Extmark movement must never update stored File Reference ranges.
- Preview uses stored ranges and authoritative staleness checks.

Highlight groups:

- `CodeReviewReference`
- `CodeReviewDraftReference`
- `CodeReviewStaleReference`
- `CodeReviewSidebarHeader`
- `CodeReviewSidebarIncomplete`
- `CodeReviewSidebarStale`
- `CodeReviewStatus`

## Sidebar

The sidebar is visible while Review Mode is active. Review Mode starts only when a visible named file buffer is available, but after start it can remain anchored by any content window, including unnamed normal buffers, outside-root normal buffers, and the Code Review preview.

Content:

- active Review header;
- scrollable Comment overview;
- File Reference list for each Comment;
- body preview truncated to 3-4 lines;
- modified relative time;
- stale/incomplete markers; and
- fixed key legend.

Behavior:

- Right vertical split.
- Width from config on open; while open, preserve the configured width or the user's adjusted sidebar width across layout changes.
- `buftype=nofile`, `readonly`, `modifiable=false`, `buflisted=false`.
- Window uses `winfixwidth`.
- Receives only local quit/help mappings, including `q` and the configured Review Mode toggle key to quit Code Review.
- Stores no durable data.
- Rendering is derived from current state and durable Review data.
- Legend remains fixed while the overview scrolls or re-renders.
- If closed directly while a content window remains, recreate on the next render or window lifecycle event.
- File explorers such as neo-tree can coexist with the sidebar; opening a file explorer must not close Review Mode.
- Code Review may close or delete only sidebar/footer windows and buffers it still owns. If a recorded sidebar/footer window ID has been reused by normal content, neo-tree, or another plugin, Code Review must not close or resize that window.
- If the last content window is closed or replaced and only auxiliary/plugin panes remain, Code Review follows the auxiliary-only confirm-all exit path.

## Comment Editor

The Comment Editor is the primary create/edit surface for Comments. It uses a stacked floating layout with a read-only status panel, a focusable read-only File References panel, and an editable comment buffer. Initial focus goes to the comment buffer. The comment buffer contains only body text; references, help, validation, and voice state are UI outside the editable body.

Composer buffer options:

- `buftype=nofile`
- `buflisted=false`
- `bufhidden=wipe`
- plugin-owned scratch name

Behavior:

- Composer text edits update draft body text, not persisted Review data.
- The status panel is not part of tab cycling.
- `<Tab>` and `<S-Tab>` cycle between the references panel and comment buffer.
- Normal `<CR>` submits the draft from the comment buffer. Insert-mode `<CR>` inserts a newline.
- Normal `<CR>` on a draft File Reference opens a picker with `Delete` and `Go to`.
- Normal `<leader>d` on a draft File Reference removes that draft reference.
- `Go to` closes the Comment Editor and jumps the source window to that File Reference.
- Normal `q` and Normal `<Esc>` cancel from composer sections.
- Normal `<leader><Space>` toggles voice recording.
- Normal `?` opens read-only Comment Editor help; `q` and `<Esc>` close help without canceling the Comment Editor.
- Submit refuses zero references or empty trimmed body and keeps the composer open.
- Canceling a new Comment Editor creates no Comment.
- Canceling an edit Comment Editor leaves the persisted Comment unchanged.
- Voice transcript inserts at the current cursor position in the draft body.
- Retryable voice errors stay in the composer with draft text preserved.

On submit:

- Copy draft buffer body lines into the Comment body.
- Copy draft references into the Comment.
- Preserve user-entered newlines.
- Update Comment and parent Review timestamps.
- Persist Review data.
- Do not write to disk.

Composer draft references should be highlighted while the composer is open and cleared on cancel. Submit converts draft references into normal persisted highlights.

## Preview

The preview action validates the active Review and opens an editable unnamed normal buffer in a main editor window. Generated review text is inserted and marked clean.

Buffer rules:

- Opens source-first: current source window for the locked root, then previous source window, then any current-tab source window.
- If no source window is visible, opens in a safe non-preview content window in the current tab.
- Never replaces auxiliary panes such as sidebar, footer, neo-tree, or other plugin buffers. If no safe target exists, preview warns and does nothing.
- Keeps Review Mode active and sidebar visible while the preview is open.
- `buftype=""`, unnamed, `buflisted=true`, `bufhidden=unload`, `filetype=code-review-preview`, `modifiable=true`, `readonly=false`, and `modified=false` after preload.
- Receives no Review Mode action mappings.
- Receives no preview-local close mappings; user/global close-buffer mappings should continue to work.
- Is editable.
- User edits make the preview buffer modified under normal Neovim rules. Saving the preview writes only that buffer's text and never mutates stored Review data.
- Only one preview buffer exists per Review Mode session.

Preview is a content buffer that keeps Review Mode alive, but it is not a source buffer. A saved preview remains a Code Review preview buffer and is not eligible for File References, even if saved inside the locked root. Source actions such as creating File References, refreshing source highlights, and source-line sidebar filtering still require named file buffers inside the locked root.

Preview is blocked if:

- any Comment is incomplete;
- any File Reference is stale;
- there are zero complete Comments;
- a composer is open;
- voice is recording/transcribing; or
- voice error is pending.

Blocking notifications include counts when useful, for example:

```text
3 incomplete comments detected, please complete or delete them
```

Re-running preview:

- Refreshes the single preview buffer in place.
- If the existing preview has unsaved edits, replacement requires explicit confirmation.
- Review Mode quit refuses to discard a modified preview buffer. It notifies the user to write or discard preview edits first.
- Raw close paths such as `:bdelete`, `:confirm q`, or closing the preview window restore the origin content buffer when possible without replacing unrelated user content. If the origin cannot be restored and other content remains, Code Review leaves that content untouched, restores Review Mode state, and keeps the sidebar coherent.

Format:

```text
Review: Auth refactor

lua/auth.lua:42-51
lua/session.lua:88-93
This validation path skips the expired-session case.

lua/ui.lua:12-20
This UI state probably needs a loading branch.
```

No Markdown formatting, comment numbering, code snippets, or automatic clipboard copy in MVP.

## Voice transcription

Voice transcription is MVP-critical and preferred. Manual Review Mode must remain fully usable when voice is unavailable.

### Auth policy

The plugin and helper must not:

- perform OAuth;
- refresh tokens;
- mutate Codex auth files;
- inspect OS credential stores;
- use API keys;
- provide an API-key fallback;
- integrate with OS keyrings; or
- add plugin-owned consent flows beyond operating-system microphone permissions.

Users are expected to have Codex CLI installed and already logged in.

Voice reads existing file-backed Codex ChatGPT auth only. If auth is missing, invalid, expired, or stale, tell the user to run `codex login`.

Expired-token notification:

```text
Codex auth token expired, please run codex login.
```

### Flow

1. Normal `<leader><Space>` in the Comment Editor starts recording for the active draft.
2. Sidebar and Comment Editor show recording state.
3. Normal `<leader><Space>` stops recording.
4. Sidebar and Comment Editor show transcribing state.
5. Successful transcription inserts text at the composer cursor.
6. Failed transcription shows retry/discard inside the composer.
7. Retry reuses the same temp audio.
8. Discard deletes temp audio and returns to the composer.

Limits:

- Maximum recording duration: 60 seconds.
- Recording request timeout: 65 seconds.
- Transcription timeout: 120 seconds.
- Reject clips shorter than 900 ms with a non-error notification.
- Reject clips larger than 16 MB before upload.
- Allow up to 3 total transcription attempts.
- Do not persist audio across sessions.

Temporary audio lives under:

```text
stdpath("cache")/code-review.nvim/voice
```

Delete temp audio after successful append, discard, max retry, or Review Mode exit.

Async completion may append only if captured `session_id`, `review_id`, and `comment_id` still match and the Comment still exists. Otherwise discard result, delete temp audio, and notify.

### Helper implementation

Runtime invokes:

```text
node voice/dist/index.js health
node voice/dist/index.js record --out <absolute-temp-wav-path> --max-ms 60000 --jsonl
node voice/dist/index.js transcribe --input <absolute-temp-wav-path> --json
```

Requirements:

- Helper source is Node/TypeScript under `voice/`.
- Runtime uses compiled JavaScript at `voice/dist/index.js`.
- Use direct HTTP requests, not the OpenAI Node SDK.
- Implement record-then-transcribe, not realtime transcription.
- Capture mono PCM from default microphone, encode as WAV, upload WAV.
- Use `decibri` as the MVP microphone capture dependency, pinned in `voice/package-lock.json`.
- If the audio provider cannot support the target platform without a compile toolchain, helper health reports `audio_provider_unavailable`; manual Review Mode still works.

Record command behavior:

- Long-running process.
- Opens default microphone.
- Starts writing WAV to requested temp path.
- Emits one JSON line after start:

```json
{ "ok": true, "event": "recording_started" }
```

Neovim stops recording by writing:

```text
stop\n
```

Neovim discards recording by writing:

```text
discard\n
```

`discard\n` stops capture, deletes partial WAV, emits, and exits zero:

```json
{ "ok": true, "event": "discarded" }
```

Successful record output:

```json
{
  "ok": true,
  "event": "recording_stopped",
  "audioBytes": 123456,
  "durationMillis": 4200,
  "mimeType": "audio/wav"
}
```

Successful transcribe output:

```json
{
  "ok": true,
  "audioBytes": 123456,
  "durationMillis": 4200,
  "model": "chatgpt-transcribe",
  "source": "chatgpt",
  "text": "This validation path skips expired sessions."
}
```

Machine-readable failure output:

```json
{
  "ok": false,
  "code": "missing_credentials",
  "message": "Run codex login and ensure auth.json exists.",
  "retryable": false
}
```

Failure codes:

- `missing_helper`
- `missing_credentials`
- `invalid_credentials`
- `codex_auth_expired`
- `audio_provider_unavailable`
- `recording_permission_denied`
- `recording_too_short`
- `audio_too_large`
- `network_error`
- `http_error`
- `empty_transcript`
- `invalid_response`
- `timeout`
- `unknown`

Exit codes:

| Code | Meaning |
| --- | --- |
| `0` | Success, including deliberate discard. |
| `1` | Expected operational failure represented by JSON error. |
| `2` | Invalid CLI arguments. |
| `3` | Unexpected internal failure; stderr must remain redacted. |
| `124` | Helper-enforced timeout. |

Lua maps JSON error codes to notifications. Nonzero exit without JSON maps to `unknown`.

### Credential discovery

Order:

1. `$CODEX_HOME/auth.json`, if `CODEX_HOME` points to a directory.
2. `~/.codex/auth.json`.
3. `~/.config/codex/auth.json`.

Rules:

- First readable existing auth file wins.
- Malformed or non-ChatGPT file-token shape returns `invalid_credentials`; do not continue to later candidates.
- Missing or unreadable candidates are skipped.
- No readable candidate returns `missing_credentials`.

Expected auth shape:

```json
{
  "auth_mode": "chatgpt",
  "tokens": {
    "id_token": "...",
    "access_token": "...",
    "account_id": "..."
  },
  "last_refresh": "2026-05-18T12:00:00Z"
}
```

Credential classification:

- Missing readable `auth.json`: `missing_credentials`.
- Malformed JSON: `invalid_credentials`.
- Not ChatGPT file-token shape: `invalid_credentials`.
- Missing `tokens.access_token`: `codex_auth_expired`.
- Malformed, non-JWT, missing-exp, expired, or within-30-seconds JWT access token: `codex_auth_expired`.

Never print token values, JWT payloads, or auth file contents. Never write, chmod, rename, back up, or otherwise mutate Codex auth files.

### Transcription endpoint

Use Codex ChatGPT file auth:

```http
POST https://chatgpt.com/backend-api/transcribe
authorization: Bearer <ChatGPT access token>
ChatGPT-Account-Id: <account id, if available>
multipart/form-data:
  file=@audio.wav
```

Expected success response: JSON with string `text`.

Mapping:

- Empty/missing/whitespace `text`: `empty_transcript`.
- Invalid JSON: `invalid_response`.
- `401`: `codex_auth_expired`.
- `403`: `http_error` with message `ChatGPT transcription endpoint rejected this account or client.`
- Fetch/DNS/TLS/connectivity failures: retryable `network_error`.
- `408`, `429`, `5xx`: retryable `http_error`.
- Other non-2xx: `http_error`.

Account id source order:

1. `tokens.account_id`
2. JWT claim `https://api.openai.com/auth.chatgpt_account_id` from `access_token`
3. Same claim from `id_token`

Omit `ChatGPT-Account-Id` if unavailable.

This endpoint is private and may fail with compatibility issues. The failure path must be clear and safe; manual Review Mode must remain usable.

## Health checks

Health checks cover plugin prerequisites and voice readiness.

Checks:

- Neovim `>= 0.11`.
- Snacks availability.
- Storage directory writability.
- Node/npm availability.
- Voice helper installed/built.
- Voice helper local readiness.
- Credential discovery/classification.
- Codex auth freshness when file auth is selected.
- DNS/TLS reachability to `chatgpt.com` when `health.network = true` and credentials are fresh.
- Audio provider availability when it can be checked safely.

Rules:

- `:CodeReviewHealth` and `:checkhealth code-review` use the same underlying checks.
- Health may use network because it is explicit diagnostics.
- Health must not upload audio.
- Health must not record audio.
- Health must not open the microphone if that may trigger an OS permission prompt.
- Health must not call `/backend-api/transcribe`.
- If audio provider availability cannot be checked safely, report `warn/not_checked`.
- If `health.network = false`, skip DNS/TLS checks and report `warn/not_checked`.
- Health never refreshes tokens and never writes Codex auth files.

Helper health output example:

```json
{
  "ok": true,
  "checks": [
    {
      "name": "node",
      "status": "ok",
      "code": "node_ready",
      "message": "Node.js 20.11.0"
    },
    {
      "name": "audio_provider",
      "status": "warn",
      "code": "not_checked",
      "message": "Audio provider check skipped to avoid opening microphone"
    },
    {
      "name": "credentials",
      "status": "ok",
      "code": "codex_file_chatgpt",
      "message": "Codex ChatGPT file auth discovered"
    }
  ],
  "credentialSource": "codex_file_chatgpt",
  "selectedEndpoint": "https://chatgpt.com/backend-api/transcribe"
}
```

`selectedEndpoint` is informational and must not imply that health probed the transcription endpoint.

User-facing fix messages:

```text
Voice helper missing: run :Lazy build code-review.nvim
No Codex file auth found: run codex login and ensure auth.json exists
Codex auth token expired: run codex login
Audio provider unavailable: install a supported helper build or use manual comments
```

## Privacy and security

Review data stores comment bodies and selected code snapshots locally under `stdpath("data")`.

Voice records audio locally and sends it to ChatGPT transcription using existing Codex file auth. Provider-side retention may apply.

Documentation must disclose:

- where Review data is stored;
- that Review data includes Comment bodies and selected code snapshots;
- that voice sends audio to ChatGPT for transcription;
- that Codex file auth is the credential source;
- that provider-side retention may apply; and
- that the plugin/helper never mutate Codex auth files.

Redaction requirements:

- Never print auth file contents.
- Never print access tokens or id tokens.
- Never print JWT payloads.
- Never print authorization headers.
- Never print raw audio bytes or base64 audio.
- Never print Comment bodies by default.
- Never print selected line snapshots by default.
- Avoid printing temp audio paths by default. If needed, print only basename plus redacted parent.
- HTTP errors may include status code and a short sanitized provider error code, not full bodies or headers.
- Do not copy Codex auth into plugin storage, logs, test artifacts, or Review data.

## Testing

Build through TDD. Write failing tests before implementation where practical.

Lua tests use Plenary and must cover:

- storage schema load/save;
- corrupt store backup;
- project root scoping;
- relative path validation;
- Review/Comment sorting;
- Comment completeness;
- File Reference creation;
- staleness detection from loaded buffers and disk;
- preview generation and blockers;
- state transitions;
- keymap registration, customization, and disabled defaults;
- no bare-key defaults;
- optional `which-key.nvim` behavior;
- sidebar creation/recreation;
- composer submit/cancel, draft reference deletion, and validation;
- extmarks remaining display-only;
- Windows path normalization;
- storage permission failure;
- clear-data while active;
- preview edits never mutating Review data;
- voice state transitions with mocked helper;
- voice cleanup across success, retry, discard, max attempts, and quit;
- voice unavailable behavior;
- `voice.enabled = false`; and
- redaction of credentials, audio paths, Comment bodies, and snapshots.

Voice helper tests must use mock auth, mock audio, and mock HTTP. They must never use real credentials, real microphones, or real ChatGPT endpoints.

Helper tests must cover:

- CLI parsing;
- credential discovery order and first-readable behavior;
- malformed, missing, stale, and expired token classification;
- account id extraction;
- read-only behavior for Codex auth files;
- request construction for `/backend-api/transcribe`;
- response and HTTP error mapping;
- audio duration and size validation;
- timeout behavior;
- record command lifecycle with mocked audio provider;
- health output schema; and
- redaction.

Concrete validation commands:

```bash
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec { minimal_init = 'tests/minimal_init.lua' }"
npm ci --prefix voice
npm test --prefix voice
npm run typecheck --prefix voice
npm run lint --prefix voice
npm run build --prefix voice
test -f voice/dist/index.js
```
