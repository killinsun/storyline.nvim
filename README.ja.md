# storyline.nvim

PR の変更内容を AI が「意味のある単位（チャプター）」に分解し、物語を読むように順番にレビューできる Neovim プラグイン。

[English README](./README.md)

- AI（Claude Code / Codex CLI / Cursor Agent）が diff を解析し、チャプター見出し + ファイル一覧を左サイドバーに表示
- チャプターは import の静的トレースに基づき「エントリポイント（上流）→ コアロジック」の順。テストは対象実装と同じチャプターで実装の直後に並ぶ（コロケーション。レビュー・読むモード共通で機械的に徹底）
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
{
  "killinsun/storyline.nvim",
  dependencies = { "lewis6991/gitsigns.nvim" },
  cmd = { "Storyline", "StorylinePick", "StorylineRead", "StorylineBackend" },
  keys = {
    { "<leader>gs", "<cmd>Storyline<cr>", desc = "ストーリーモードレビュー" },
    { "<leader>gS", "<cmd>StorylinePick<cr>", desc = "base を選んでストーリーモードレビュー" },
    { "<leader>sl", "<cmd>StorylineRead<cr>", desc = "トピックでコードを読む" },
  },
  opts = {},
}
```

詳細なリファレンスは `:help storyline`（英語）を参照。

## 使い方

| 操作 | キー / コマンド |
| --- | --- |
| レビュー開始（比較範囲を選択） | `:Storyline` |
| 比較範囲を選んで開始 | `:StorylinePick` |
| トピックで読む（diff なし） | `:StorylineRead` / `<leader>sl`（AI が切り口を提案 → チャットで選択 → 解析） |
| AI バックエンド切替 | `:StorylineBackend` |
| キャッシュ無視で再解析 | `:StorylineRefresh`（サイドバーで `R`） |

`:StorylineRead` の候補は文字列一致の羅列ではない。パスがトピックに一致したファイルを
起点（seed）に import / require を静的にトレースし、呼び出し元（エントリポイント）から
呼び出し先（コアロジック）まで依存で繋がるファイルだけを「上流 → コア」の順で残す。
テストは対象実装の直後に並ぶ（コロケーション）。切り口を選んで絞り込んだときも import で
繋がる上流・下流を残すので、読み筋が途切れない。

### サイドバー

`j/k` 移動、`h/l` チャプター折畳/展開、`<CR>` チャプター概要 / ファイルを開く、`<Tab>` フォーカスを残して開く（プレビュー）、`o` 概要フロート、`v` チャプターを Diffview で開く、`m` 読了トグル（ファイル行ならファイル、チャプター行ならチャプター）、`a` チャプターについて LLM に質問、`A` ストーリーの組み替えを指示、`B` 比較範囲を選び直す、`]c` `[c` チャプター移動、`q` 終了。which-key.nvim が入っていればサイドバーで `<Space>` を押すとこれらの操作が一覧表示される。

起動時（および `B`）では **PR base から** / **コミットから HEAD** を選べる。PR base 選択は `opts.pick_base` で差し替え可能（例: ホストの telescope ブランチ picker）。

`A` では「この PR の一番キーとなるものでまとめて」「リクエストごとに resolver から辿れるように」など自然言語で指示でき、LLM がチャプター構成を組み替えてサイドバーを更新する。ファイルの読了は `✓` / `·` で表示され、開いたとき、または `m` でトグルできる。

ファイル一覧は GitHub の PR ツリーのように**ディレクトリ階層**で表示する（デフォルト）。単一子ディレクトリの連鎖は `worker/handlers` のように1行へ連結し、ファイル名のステータス（追加=緑 / 削除=赤 / リネーム=黄）と `+N -M` を色付きで表示。nvim-web-devicons があればファイルアイコンも出る。

`sidebar_style = "flat"` でフルパス一覧表示（共通ディレクトリの畳み込み + 短縮つき）に切り替え可能。

### メインペイン

実ファイルバッファなので LSP ジャンプが通常どおり有効。`<leader>gl` で unified / split 切替（変更可能）。

## 設定

```lua
require("storyline").setup({
  backend = "claude", -- "claude" | "codex" | "cursor" | "auto"
  layout = "unified", -- 初期レイアウト
  auto_split_lines = 80, -- 変更行数がこの値以上で split へ自動切替（0 で無効）
  -- pick_base = function(cb) require("config.git").pick_base_branch(cb) end,
  unified = {
    word_diff = false, -- unified 表示で単語単位 diff（デフォルト off）
    diff_opts = { algorithm = "histogram", indent_heuristic = true },
  },
  max_diff_lines_per_file = 400,
  sidebar_width = 36,
  sidebar_style = "tree", -- "tree"（GitHub 風ツリー）| "flat"（パス一覧）
  shorten_paths = true, -- flat 時の共通ディレクトリ畳み込みとパス短縮
  auto_summary = true,
  keymaps = { toggle_layout = "<leader>gl" },
  prompts = {
    -- チャプター分解プロンプトへの追加指示
    analyze_extra = "チャプター名は英語で書く",
    -- チャプター質問（a キー）への追加指示
    ask_extra = "回答は箇条書きで",
    -- プロンプト全体の差し替え（上級者向け。analyze は JSON スキーマ指示も自前で含めること）
    -- build_analyze = function(ctx) return "..." end,   -- ctx: { files, stat, diff, pr }
    -- build_question = function(args) return "..." end, -- args: { story_title, base_ref, chapter, diff, question }
  },
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
