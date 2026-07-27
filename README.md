# storyline.nvim

Read a pull request as a story. An AI CLI splits the diff into meaningful **chapters**, and you walk through them in reading order instead of going file by file in alphabetical order.

[日本語 README](./README.ja.md)

- AI (Claude Code / Codex CLI / Cursor Agent) analyses the diff and returns chapters — title, summary, review points, and the files that belong to each one
- Chapters and their files are listed in a sidebar, as a directory tree that looks like GitHub's PR file tree
- Selecting a chapter shows its summary and what to look for
- **The main pane is the real file buffer**, so `gd` / `gr` / hover work as usual — the main difference from a dedicated diff viewer
- The diff is drawn by gitsigns, switchable between unified and split

## Requirements

- Neovim 0.10+
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim)
- One AI CLI: `claude`, `codex` or `cursor-agent` (without any of them the plugin falls back to grouping files by directory)
- Optional: `gh` (detects the PR base branch), [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim), [diffview.nvim](https://github.com/sindrets/diffview.nvim), [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons), [which-key.nvim](https://github.com/folke/which-key.nvim)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "killinsun/storyline.nvim",
  dependencies = { "lewis6991/gitsigns.nvim" },
  cmd = { "Storyline", "StorylinePick", "StorylineRead", "StorylineBackend" },
  keys = {
    { "<leader>gs", "<cmd>Storyline<cr>", desc = "Story-mode review" },
    { "<leader>gS", "<cmd>StorylinePick<cr>", desc = "Review, picking the base" },
    { "<leader>sl", "<cmd>StorylineRead<cr>", desc = "Read code by topic" },
  },
  opts = {},
}
```

## Usage

| Action | Command |
| --- | --- |
| Start a review (choose the compare range) | `:Storyline` |
| Start a review, picking the base branch | `:StorylinePick` |
| Read by topic, no diff involved | `:StorylineRead` (AI proposes angles → refine in a chat → analyse) |
| Switch AI backend | `:StorylineBackend` |
| Re-analyse, ignoring the cache | `:StorylineRefresh` (or `R` in the sidebar) |

On start (and with `B`) you choose between **from the PR base** (merge-base → working tree) and **from a commit to HEAD**. The base picker is replaceable via `opts.pick_base`.

### Sidebar

| Key | Action |
| --- | --- |
| `<CR>` | Chapter summary / open the file |
| `<Tab>` | Open the file, keep focus in the sidebar (preview) |
| `h` / `l` | Collapse / expand the chapter |
| `o` | Chapter summary float |
| `v` | Open the whole chapter in diffview.nvim |
| `m` | Toggle read state (file line: that file; chapter line: all of them) |
| `a` | Ask the LLM about this chapter |
| `A` | Tell the LLM how to reorganize the story |
| `B` | Pick a different compare range |
| `]c` / `[c` | Next / previous chapter |
| `q` | Close |
| `<Space>` | List these keys (requires which-key.nvim) |

`A` takes free text — "group it around the single key change of this PR", "order it so each request can be traced from its resolver" — and the LLM rebuilds the chapter layout in place.

Read files show `✓`, unread `·`. Opening a file marks it read.

The file list is a directory tree by default: chains of single-child directories are joined onto one line like `worker/handlers`, file names are coloured by status (green added / red deleted / yellow renamed) and followed by `+N -M`. `sidebar_style = "flat"` switches to a plain path list.

### Main pane

The real file buffer, so LSP navigation is unaffected. `<leader>gl` toggles unified / split.

### Read mode

`:StorylineRead` drops the diff and structures existing code around a topic — useful for onboarding onto an unfamiliar area. The AI scouts the repository and proposes topics; instructions like "only under `apps/api`", "exclude tests" or "just the resolvers" narrow the candidates before analysis.

## Configuration

```lua
require("storyline").setup({
  backend = "claude", -- "claude" | "codex" | "cursor" | "auto"
  timeout_ms = 120000,
  layout = "unified", -- initial diff layout
  auto_split_lines = 80, -- open files with >= N changed lines in split (0 disables)
  unified = {
    word_diff = false,
    diff_opts = { algorithm = "histogram", indent_heuristic = true },
  },
  max_diff_lines_per_file = 400,
  sidebar_width = 36,
  sidebar_style = "tree", -- "tree" | "flat"
  shorten_paths = true,
  auto_read_mark = true,
  auto_summary = true,
  -- plug in your own base branch picker
  -- pick_base = function(cb) require("config.git").pick_base_branch(cb) end,
  keymaps = {
    toggle_layout = "<leader>gl",
    preview = "<Tab>",
  },
  prompts = {
    -- appended to the built-in prompts as extra instructions
    analyze_extra = "Write chapter titles in English",
    read_extra = "",
    ask_extra = "Answer as a bullet list",
    -- full replacement (advanced; build_analyze must include the JSON schema itself)
    -- build_analyze = function(ctx) return "..." end,   -- ctx: { files, stat, diff, pr }
    -- build_question = function(args) return "..." end, -- args: { story_title, base_ref, chapter, diff, question }
  },
})
```

See `:help storyline` for the full reference.

## Caching

Analysis is cached per HEAD and per set of changed files, so editing a line mid-review does not trigger a re-analysis — adding or removing a file does. On a cache hit the stored chapters are reconciled with the current file set. Read state is persisted per compare range.

## Diagnostics

```
:checkhealth storyline
```

## Tests

```bash
make test
```

## License

MIT
