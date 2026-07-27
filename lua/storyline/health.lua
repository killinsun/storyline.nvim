local M = {}

function M.check()
  local health = vim.health
  local config = require("storyline.config")

  health.start("storyline.nvim")

  if vim.fn.executable("git") == 1 then
    health.ok("git が見つかりました")
  else
    health.error("git が見つかりません")
  end

  local ok = pcall(require, "gitsigns")
  if ok then
    health.ok("gitsigns.nvim が読み込めます")
    local actions_ok, actions = pcall(require, "gitsigns")
    if actions_ok and type(actions.toggle_deleted) ~= "function" then
      health.warn(
        "gitsigns.toggle_deleted がありません（gitsigns の更新で削除された可能性。unified 表示に影響します）"
      )
    end
  else
    health.error("gitsigns.nvim が必要です（unified/split 表示に使用）")
  end

  local any = false
  for name, cfg in pairs(config.options.backends) do
    if vim.fn.executable(cfg.cmd) == 1 then
      health.ok(("AI バックエンド %s: %s"):format(name, cfg.cmd))
      any = true
    else
      health.info(("AI バックエンド %s: %s が見つかりません"):format(name, cfg.cmd))
    end
  end
  if not any then
    health.warn(
      "AI バックエンドが1つもありません（ディレクトリ単位のフォールバックのみ動作します）"
    )
  end

  if vim.fn.executable("gh") == 1 then
    health.ok("gh が見つかりました（PR の base ブランチを自動検出できます）")
  else
    health.info("gh がありません（base は origin/HEAD にフォールバック）")
  end
end

return M
