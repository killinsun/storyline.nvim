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
  -- "unified" | "split"
  layout = "unified",
  -- チャプター内の全ファイルを開いたら自動で読了マーク
  auto_read_mark = true,
  -- チャプター切替時に概要フロートを自動表示
  auto_summary = true,
  keymaps = {
    toggle_layout = "<leader>gl",
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
