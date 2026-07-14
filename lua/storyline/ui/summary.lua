local config = require("storyline.config")

local M = { win = nil }

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win = nil
end

--- チャプターの概要と読むポイントをフロートで表示する。
--- フォーカスを奪うので q / <Esc> で閉じて元のウィンドウへ戻れる。
function M.show(chapter)
  if not chapter then
    return
  end
  M.close()

  local lines = { "# " .. chapter.id .. ". " .. chapter.title, "" }
  if chapter.summary ~= "" then
    for _, l in ipairs(vim.split(chapter.summary, "\n", { plain = true })) do
      table.insert(lines, l)
    end
    table.insert(lines, "")
  end
  if #chapter.review_points > 0 then
    table.insert(lines, "## 読むポイント")
    for _, point in ipairs(chapter.review_points) do
      table.insert(lines, "- " .. point)
    end
    table.insert(lines, "")
  end
  table.insert(lines, ("対象ファイル: %d 件"):format(#chapter.files))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local width = math.min(72, vim.o.columns - config.options.sidebar_width - 8)
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))
  M.win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 2,
    col = config.options.sidebar_width + 4,
    width = math.max(width, 40),
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Storyline ",
  })
  vim.wo[M.win].wrap = true
  vim.wo[M.win].linebreak = true

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, M.close, { buffer = buf, nowait = true, desc = "Storyline: 概要を閉じる" })
  end
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = M.close,
  })
end

return M
