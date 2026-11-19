# harness.nvim

Lightweight Neovim PTY bridge for terminal AI coding harnesses
([`omp`](https://github.com/can1357/oh-my-pi), `agy` / Antigravity,
[`opencode`](https://github.com/sst/opencode),
[`codex`](https://github.com/openai/codex), and
[`claude`](https://code.claude.com/docs/en/overview) / Claude Code).

Inspired from [opencode.nvim](https://github.com/nickjvandyke/opencode.nvim).

## Requirements

- Neovim >= 0.10
- [`folke/snacks.nvim`](https://github.com/folke/snacks.nvim) (`terminal`, `picker`, `input`)
- One or more supported harnesses on `PATH`: `omp`, `agy`, `opencode`, `codex`, `claude`

## Features & Specs

| Feature | `omp` | `agy` (Antigravity) | `opencode` | `codex` (Codex CLI) | `claude` (Claude Code) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Model catalog** | `omp models --json` | `agy --output-format json models` | Built-in TUI (`/models`) | Built-in TUI (`/model`) | Built-in TUI (`/model`) |
| **Model switch** | `/switch <selector>:<effort>` | `/model <id>` | `/models` (TUI dialog) | `/model` (TUI popup) | `/model` (TUI picker) |
| **Thinking picker** | `/effort <level>` (`off`..`auto`) | `/effort <level>` (`minimal`..`max`) | `<C-t>` (`\20` variant cycle) | `/model` (TUI popup) | `/effort` (TUI slider) |
| **Thinking cycle** | `<S-Tab>` (`\27[Z`) | `/effort <level>` (`minimal`..`max`) | `<C-t>` (`\20` variant cycle) | `/model` (TUI popup) | `/effort` (TUI slider) |
| **Subword picker** | `[provider] model · effort reasoning  (Name)` (e.g. `sonnet hi`, `gpt hig`) | Same format | TUI filter | TUI selector | TUI selector |
| **Async cache** | Preloaded on `setup()`, 0 ms open, stale-while-revalidate refresh | Same | N/A | N/A | N/A |

- **Harness dropdown & auto-open**: `require("harness").switch()` (`<leader>as`) opens a dropdown menu (`omp`, `agy`, `opencode`, `codex`, `claude`) and opens the selected AI panel on acceptance. Pressing `<C-.>` (`toggle()`) when no harness is selected yet also opens this dropdown first.
- **Terminal image previews**: Forwards Kitty graphics APC sequences (`\27_G...`) and Unicode placeholders (`U+10EEEE`) from `snacks.terminal` buffers to the outer terminal.
- **No default keymaps**: `require("harness").setup(opts)` binds no keys. See below for a `Lazy.nvim` config example.

Select Claude Code with `require("harness").switch("claude")`, or set
`default = "claude"` in `setup()` options. Use a current Claude Code release
with [`/effort`](https://code.claude.com/docs/en/model-config#adjust-effort-level)
support; available effort levels depend on its active model. Both thinking
actions open Claude's native slider rather than tracking or cycling levels in Neovim.

## `lazy.nvim` Configuration

```lua
{
  "DavidLapous/harness.nvim",
  dependencies = {
    {
      "folke/snacks.nvim",
      opts = {
        terminal = { enabled = true },
        picker = { enabled = true },
        input = { enabled = true },
      },
    },
  },
  lazy = false,
  opts = {
    win = { position = "right", width = 0.4 },
    preload_models = true,
  },
  keys = {
    { "<C-.>", function() require("harness").toggle() end, mode = { "n", "x", "t" }, desc = "Toggle AI harness" },
    { "go", function() return require("harness").send_operator() end, mode = { "n", "x" }, expr = true, desc = "Send range/selection to AI" },
    { "goo", function() return require("harness").send_line() end, mode = "n", expr = true, desc = "Send line to AI" },
    { "<leader>ai", function() require("harness").ask() end, mode = { "n", "x" }, desc = "Ask AI (line/selection)" },
    { "<leader>am", function() require("harness").pick_model() end, mode = "n", desc = "[A]I [S]witch model" },
    { "<leader>at", function() require("harness").pick_thinking() end, mode = "n", desc = "[A]I [T]hinking level" },
    { "<leader>av", function() require("harness").cycle_thinking() end, mode = "n", desc = "Cycle AI thinking level" },
    { "<leader>as", function() require("harness").switch() end, mode = "n", desc = "[A]I [S]witch harness" },
    { "<leader>ab", function() require("harness").bottom() end, mode = "n", desc = "[A]I [B]ottom" },
    { "<leader>ar", function() require("harness").right() end, mode = "n", desc = "[A]I [R]ight" },
  },
}
```

## API

| Function | Description |
| :--- | :--- |
| `require("harness").setup(opts)` | Initialize options (`default`, `win`, `preload_models`), configure terminal Kitty graphics passthrough, and background-preload model catalogs. |
| `require("harness").toggle()` | Toggle the active harness terminal split (or open the harness dropdown if none is selected yet). |
| `require("harness").switch(name?)` | Open the harness dropdown menu (or switch directly to `"omp"`, `"agy"`, `"opencode"`, `"codex"`, or `"claude"` if `name` is given) and show its AI panel. |
| `require("harness").current()` | Return active harness name (`"omp"`, `"agy"`, `"opencode"`, `"codex"`, `"claude"`, or `nil` before selection). |
| `require("harness").bottom()` | Move the harness terminal split to the bottom (`position = "bottom"`). |
| `require("harness").right()` | Move the harness terminal split to the right (`position = "right"`). |
| `require("harness").left()` | Move the harness terminal split to the left (`position = "left"`). |
| `require("harness").top()` | Move the harness terminal split to the top (`position = "top"`). |
| `require("harness").ask(a?, b?)` | Prompt via `vim.ui.input` prefilled with a pointer and submit. Characterwise Visual (`v`) selections get an exact byte range (see [Selection pointer](#selection-pointer)); otherwise `path:line at "word": ` (or `at Nth "word"` when repeated on the line, `:col` 1-based byte column when not on an identifier/word, or `path:start-end: ` for multi-line linewise/blockwise selections and explicit `a`/`b` ranges). |
| `require("harness").prompt_range(a?, b?)` | Paste fenced code excerpt into the active harness composer without submitting. |
| `require("harness").send_operator()` | `expr = true` operator helper for sending a motion or visual selection (e.g. `go`). |
| `require("harness").send_line()` | `expr = true` operator helper for sending the current line (e.g. `goo`). |
| `require("harness").pick_model()` | Open `vim.ui.select` (`snacks.picker`) with provider, model, and reasoning effort subword search (`omp`, `agy`) or open the built-in TUI model dialog (`opencode`, `codex`, `claude`). |
| `require("harness").pick_thinking()` | Open `vim.ui.select` dropdown to switch reasoning effort only while keeping the current model (`/effort <level>` in `omp`/`agy`, `/model` in `codex`, `/effort` in `claude`, `<C-t>` in `opencode`). |
| `require("harness").cycle_thinking(direction?)` | Cycle reasoning effort (`"forward"` default, or `"backward"` for `agy`); open the native selector instead in `codex`/`claude`. |

## Selection pointer

`ask()` called from characterwise Visual mode (`v`, no explicit range) prefills
one editable line naming the exact selected bytes (the prefill ends with `: `):

```text
src/index.cpp:42:50-53 "a, b" (in build_index):
src/index.cpp:42:26-45:9 from "sort(runs, &cfg)" to "limit" (in build_index):
```

- Coordinates are `line:start_col-end_col` or `start_line:start_col-end_line:end_col`:
  1-based, inclusive UTF-8 byte columns of the region Visual mode selects, computed
  from the two Visual endpoints only (`getregionpos()` on the end line plus
  'selection'). Both endpoints are always shown, order is normalized for backward
  selections, and the end column is the last byte of the last selected character.
  A selected line break (`$`, an empty line, or an exclusive end in column 1) is
  column `line length + 1`; the buffer's last line break is never selected.
- The quoted hint is the selection when it has at most 48 characters, otherwise
  its first and last 24 characters joined by `…`. Multi-line selections show a
  start anchor (from the start to the end of its line) and an end anchor (from
  the start of its line to the end), at most 24 characters each, with blanks
  trimmed only on the side away from the coordinate. Hints escape `"`, `\`, tab,
  LF, CR, other C0 controls, DEL and invalid bytes (`\xhh`), and C1 controls and
  U+2028/U+2029 (`\uhhhh`); the path gets the same control escapes, so the
  pointer stays on one line. Only a few hundred bytes at the ends are read.
- `[unsaved]` follows the coordinates when the buffer is modified.
- `(in NAME)` names the innermost Python or C++ function/method that contains
  both selected endpoints, using an installed parser via `vim.treesitter` (no
  LSP, no parser installation). Buffers up to 32 KiB are parsed on demand;
  larger ones only use an up-to-date tree from an active Tree-sitter
  highlighter. It is omitted for other filetypes, missing parsers, syntax
  errors anywhere in the buffer, endpoints in different functions (including
  nested siblings and an outer/inner pair; a selected line break after a
  function's last line is outside it), and unnamed or unusual definitions
  (lambdas resolve to their enclosing named function; C++ definitions without
  a return type are named only when they are constructors or destructors).
- `'selection'` `old`, `'virtualedit'` containing `all` (window-local value, or
  the global one when that is empty), virtual positions and regions without a
  selectable byte keep the line pointer described in the API table.
