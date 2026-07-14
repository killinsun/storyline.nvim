# storyline.nvim

PR の変更内容を AI が「意味のある単位（チャプター）」に分解し、物語を読むように順番にレビューできる Neovim プラグイン。

- AI（Claude Code / Codex CLI / Cursor Agent）が diff を解析し、チャプター見出し + ファイル一覧を左サイドバーに表示
- チャプター選択時に「概要と読むポイント」をフロートで表示
- メインペインは常に**実ファイルバッファ**なので、LSP のコードジャンプ（`gd` / `gr` / hover）がそのまま使える
- diff 表示は gitsigns ベースで unified / split を切り替え可能

## 必要なもの

- Neovim 0.10+
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim)
- AI CLI のいずれか: `claude` / `codex` / `cursor-agent`（無くてもディレクトリ単位のフォールバックで動作）
- `gh`（任意。PR の base ブランチ自動検出に使用）

## セットアップ（lazy.nvim）

```lua
return {
  dir = vim.fn.expand("~/src/github.com/killinsun/storyline.nvim"),
  name = "storyline.nvim",
  dependencies = { "lewis6991/gitsigns.nvim" },
  cmd = { "Storyline", "StorylinePick", "StorylineBackend" },
  keys = {
    { "<leader>gs", "<cmd>Storyline<cr>", desc = "ストーリーモードレビュー" },
    { "<leader>gS", "<cmd>StorylinePick<cr>", desc = "base を選んでストーリーモードレビュー" },
  },
  opts = {},
}
```

## 使い方

| 操作 | キー / コマンド |
| --- | --- |
| レビュー開始（base 自動検出） | `:Storyline` |
| base ブランチを選んで開始 | `:StorylinePick` |
| AI バックエンド切替 | `:StorylineBackend` |
| キャッシュ無視で再解析 | `:StorylineRefresh`（サイドバーで `R`） |

### サイドバー

`j/k` 移動、`h/l` チャプター折畳/展開、`<CR>` チャプター概要 / ファイルを開く、`p` フォーカスを残して開く、`o` 概要フロート、`v` チャプターを Diffview で開く、`m` 読了トグル、`]c` `[c` チャプター移動、`q` 終了。

深い階層のリポジトリでは、チャプター内ファイルの共通ディレクトリを1行に畳み、収まらないパスは `a/b/file.ts` 形式に短縮して表示する（`shorten_paths = false` で無効化）。

### メインペイン

実ファイルバッファなので LSP ジャンプが通常どおり有効。`<leader>gl` で unified / split 切替（変更可能）。

## 設定

```lua
require("storyline").setup({
  backend = "claude", -- "claude" | "codex" | "cursor" | "auto"
  layout = "unified", -- 初期レイアウト
  max_diff_lines_per_file = 400,
  sidebar_width = 36,
  shorten_paths = true, -- 共通ディレクトリの畳み込みとパス短縮
  auto_summary = true,
  keymaps = { toggle_layout = "<leader>gl" },
})
```

## テスト

```bash
make test
```

## 診断

```
:checkhealth storyline
```
