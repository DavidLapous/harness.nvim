# harness.nvim

Lightweight Neovim PTY bridge for terminal AI coding harnesses ([`omp`](https://github.com/can1357/oh-my-pi), `agy` / Antigravity, [`opencode`](https://github.com/sst/opencode), and [`codex`](https://github.com/openai/codex)).

Drives the active harness inside `snacks.terminal` directly over its PTY channel using bracketed paste (`\27[200~...\27[201~`)—no socket sidecar or background daemon required.

## Requirements

- Neovim >= 0.10
- [`folke/snacks.nvim`](https://github.com/folke/snacks.nvim) (`terminal`, `picker`, `input`)
- One or more supported harnesses on `PATH`: `omp`, `agy`, `opencode`, `codex`

## Features & Specs

| Feature | `omp` | `agy` (Antigravity) | `opencode` | `codex` (Codex CLI) |
| :--- | :--- | :--- | :--- | :--- |
| **Model catalog** | `omp models --json` | `agy --output-format json models` | Built-in TUI (`/models`) | Built-in TUI (`/model`) |
| **Model switch** | `/switch <selector>:<effort>` | `/model <id>` | `/models` (TUI dialog) | `/model` (TUI popup) |
| **Thinking cycle** | `<S-Tab>` (`\27[Z`) | `/effort <level>` (`minimal`..`max`) | `<C-t>` (`\20` variant cycle) | `/model` (TUI popup) |
| **Subword picker** | `[provider] model · effort reasoning  (Name)` (e.g. `sonnet hi`, `gpt hig`) | Same format | TUI filter | TUI selector |
| **Async cache** | Preloaded on `setup()`, 0 ms open, stale-while-revalidate refresh | Same | N/A | N/A |

- **Harness dropdown & auto-open**: `require("harness").switch()` (`<leader>as`) opens a dropdown menu (`omp`, `agy`, `opencode`, `codex`) and opens the selected AI panel on acceptance. Pressing `<C-.>` (`toggle()`) when no harness is selected yet also opens this dropdown first.
- **No default keymaps**: `require("harness").setup(opts)` binds no keys. Configure your own in `lazy.nvim`.

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
    { "<leader>am", function() require("harness").pick_model() end, mode = "n", desc = "Switch AI model" },
    { "<leader>av", function() require("harness").cycle_thinking() end, mode = "n", desc = "Cycle AI thinking level" },
    { "<leader>as", function() require("harness").switch() end, mode = "n", desc = "[A]I [S]witch harness" },
  },
}
```

## API

- `require("harness").setup(opts)` — initialize options (`default`, `win`, `preload_models`) and background-preload model catalogs.
- `require("harness").toggle()` — toggle the active harness terminal split (or open the harness dropdown if none is selected yet).
- `require("harness").switch(name?)` — open the harness dropdown menu (or switch directly to `"omp"`, `"agy"`, `"opencode"`, or `"codex"` if `name` is given) and show its AI panel.
- `require("harness").current()` — return active harness name (`"omp"`, `"agy"`, `"opencode"`, `"codex"`, or `nil` before selection).
- `require("harness").ask(a?, b?)` — prompt via `vim.ui.input` prefilled with `path:line at "word": ` (or `at Nth "word"` when repeated on the line, `:col` 1-based byte column when not on an identifier/word, or `path:start-end: ` for multi-line selections) and submit.
- `require("harness").prompt_range(a?, b?)` — paste fenced code excerpt into the active harness composer without submitting.
- `require("harness").send_operator()` / `require("harness").send_line()` — `expr = true` helpers for `go` / `goo`.
- `require("harness").pick_model()` — open `vim.ui.select` (`snacks.picker`) with provider, model, and reasoning effort subword search (`omp`, `agy`) or open the built-in TUI model dialog (`opencode`, `codex`).
- `require("harness").cycle_thinking(direction?)` — cycle reasoning effort (`"forward"` default, or `"backward"`).
