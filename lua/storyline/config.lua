local M = {}

M.defaults = {
  -- "claude" | "codex" | "cursor" | "auto"（auto は available な先着）
  backend = "claude",
  backends = {
    claude = { cmd = "claude", args = { "-p" } },
    codex = { cmd = "codex", args = { "exec", "--sandbox", "read-only", "-" } },
    cursor = { cmd = "cursor-agent", args = { "-p" } },
  },
  timeout_ms = 120000,
  -- プロンプトに含める diff の1ファイルあたり上限行数
  max_diff_lines_per_file = 400,
  sidebar_width = 36,
  -- "tree": GitHub の PR ツリーのようにディレクトリ階層で表示（単一子ディレクトリは連結）
  -- "flat": パスをそのまま一覧表示
  sidebar_style = "tree",
  -- flat 表示時: チャプター内の共通ディレクトリを1行に畳み、収まらないパスを短縮
  shorten_paths = true,
  -- "unified" | "split"
  layout = "unified",
  -- チャプター内の全ファイルを開いたら自動で読了マーク
  auto_read_mark = true,
  -- チャプター切替時に概要フロートを自動表示
  auto_summary = true,
  keymaps = {
    toggle_layout = "<leader>gl",
    -- サイドバー: フォーカスを残したままファイルを開く
    preview = "<Tab>",
  },
  -- プロンプトのカスタマイズ
  prompts = {
    -- チャプター分解プロンプトに「追加の指示」として追記する文字列
    -- 例: "チャプター名は英語で書く" / "テストは実装と同じチャプターに入れる"
    analyze_extra = "",
    -- チャプター質問（サイドバー a）プロンプトへの追記
    ask_extra = "",
    -- プロンプト全体を差し替える関数（上級者向け）。
    -- build_analyze = function(ctx) ... return string end
    --   ctx: { files, stat, diff, pr }。出力 JSON スキーマの指示も自前で含めること。
    -- build_question = function(args) ... return string end
    --   args: { story_title, base_ref, chapter, diff, question }
    build_analyze = nil,
    build_question = nil,
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
