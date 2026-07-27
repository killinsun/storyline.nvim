if vim.g.loaded_storyline then
  return
end
vim.g.loaded_storyline = 1

vim.api.nvim_create_user_command("Storyline", function(cmd)
  require("storyline").start({ base = cmd.args ~= "" and cmd.args or nil })
end, {
  nargs = "?",
  complete = "customlist,v:lua.require'storyline.git'.complete_branches",
  desc = "ストーリーモードレビューを開始",
})

vim.api.nvim_create_user_command("StorylinePick", function()
  require("storyline").start_with_picker()
end, { desc = "base ブランチを選んでストーリーモードレビューを開始" })

vim.api.nvim_create_user_command("StorylineRead", function(cmd)
  local topic = vim.trim(cmd.args or "")
  if topic == "" then
    require("storyline").start_read_interactive()
  else
    require("storyline").start_read(topic)
  end
end, { nargs = "*", desc = "トピックで読むべきコードをストーリー表示（diff なし）" })

vim.api.nvim_create_user_command("StorylineRefresh", function()
  require("storyline").refresh()
end, { desc = "キャッシュを無視して AI 解析をやり直す" })

vim.api.nvim_create_user_command("StorylineClose", function()
  require("storyline").close()
end, { desc = "ストーリーモードレビューを閉じる" })

vim.api.nvim_create_user_command("StorylineBackend", function()
  require("storyline.ai").pick_backend()
end, { desc = "AI バックエンドを切り替える" })
