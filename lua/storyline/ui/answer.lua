local M = { win = nil }

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win = nil
end

--- チャプターへの質問と AI の回答をフロートで表示する。
--- フォーカスを奪うので q / <Esc> で閉じて元のウィンドウへ戻れる。
function M.show(question, answer_text)
  M.close()

  local lines = { "Q: " .. question, "---", "" }
  for _, l in ipairs(vim.split(answer_text or "", "\n", { plain = true })) do
    table.insert(lines, l)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local width = math.floor(vim.o.columns * 0.6)
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.7))
  M.win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = math.max(width, 40),
    height = math.max(height, 3),
    style = "minimal",
    border = "rounded",
    title = " Storyline 質問 ",
  })
  vim.wo[M.win].wrap = true
  vim.wo[M.win].linebreak = true

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, M.close, { buffer = buf, nowait = true, desc = "Storyline: 回答を閉じる" })
  end
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = M.close,
  })
end

return M
