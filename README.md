# harness.nvim

Lightweight Neovim PTY bridge for terminal AI coding harnesses
([`omp`](https://github.com/can1357/oh-my-pi), `agy` / Antigravity,
[`opencode`](https://github.com/sst/opencode), and
[`codex`](https://github.com/openai/codex)).

Inspired from [opencode.nvim](https://github.com/nickjvandyke/opencode.nvim).

## Requirements

- Neovim >= 0.10
- [`folke/snacks.nvim`](https://github.com/folke/snacks.nvim) (`terminal`, `picker`, `input`)
- One or more supported harnesses on `PATH`: `omp`, `agy`, `opencode`, `codex`

## Features & Specs

| Feature | `omp` | `agy` (Antigravity) | `opencode` | `codex` (Codex CLI) |
| :--- | :--- | :--- | :--- | :--- |
| **Model catalog** | `omp models --json` | `agy --output-format json models` | Built-in TUI (`/models`) | Built-in TUI (`/model`) |
| **Model switch** | `/switch <selector>:<effort>` | `/model <id>` | `/models` (TUI dialog) | `/model` (TUI popup) |
| **Thinking picker** | `/effort <level>` (`off`..`auto`) | `/effort <level>` (`minimal`..`max`) | `<C-t>` (`\20` variant cycle) | `/model` (TUI popup) |
| **Thinking cycle** | `<S-Tab>` (`\27[Z`) | `/effort <level>` (`minimal`..`max`) | `<C-t>` (`\20` variant cycle) | `/model` (TUI popup) |
| **Subword picker** | `[provider] model · effort reasoning  (Name)` (e.g. `sonnet hi`, `gpt hig`) | Same format | TUI filter | TUI selector |
| **Async cache** | Preloaded on `setup()`, 0 ms open, stale-while-revalidate refresh | Same | N/A | N/A |

- **Harness dropdown & auto-open**: `require("harness").switch()` (`<leader>as`) opens a dropdown menu (`omp`, `agy`, `opencode`, `codex`) and opens the selected AI panel on acceptance. Pressing `<C-.>` (`toggle()`) when no harness is selected yet also opens this dropdown first.
- **Terminal image previews**: Forwards Kitty graphics APC sequences (`\27_G...`) and Unicode placeholders (`U+10EEEE`) from `snacks.terminal` buffers to the outer terminal.
- **No default keymaps**: `require("harness").setup(opts)` binds no keys. See below for a `Lazy.nvim` config example.

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
| `require("harness").switch(name?)` | Open the harness dropdown menu (or switch directly to `"omp"`, `"agy"`, `"opencode"`, or `"codex"` if `name` is given) and show its AI panel. |
| `require("harness").current()` | Return active harness name (`"omp"`, `"agy"`, `"opencode"`, `"codex"`, or `nil` before selection). |
| `require("harness").bottom()` | Move the harness terminal split to the bottom (`position = "bottom"`). |
| `require("harness").right()` | Move the harness terminal split to the right (`position = "right"`). |
| `require("harness").left()` | Move the harness terminal split to the left (`position = "left"`). |
| `require("harness").top()` | Move the harness terminal split to the top (`position = "top"`). |
| `require("harness").ask(a?, b?)` | Prompt via `vim.ui.input` prefilled with `path:line at "word": ` (or `at Nth "word"` when repeated on the line, `:col` 1-based byte column when not on an identifier/word, or `path:start-end: ` for multi-line selections) and submit. |
| `require("harness").prompt_range(a?, b?)` | Paste fenced code excerpt into the active harness composer without submitting. |
| `require("harness").send_operator()` | `expr = true` operator helper for sending a motion or visual selection (e.g. `go`). |
| `require("harness").send_line()` | `expr = true` operator helper for sending the current line (e.g. `goo`). |
| `require("harness").pick_model()` | Open `vim.ui.select` (`snacks.picker`) with provider, model, and reasoning effort subword search (`omp`, `agy`) or open the built-in TUI model dialog (`opencode`, `codex`). |
| `require("harness").pick_thinking()` | Open `vim.ui.select` dropdown to switch reasoning effort only while keeping the current model (`/effort <level>` in `omp`/`agy`, `/model` in `codex`, `<C-t>` in `opencode`). |
| `require("harness").cycle_thinking(direction?)` | Cycle reasoning effort (`"forward"` default, or `"backward"`). |
