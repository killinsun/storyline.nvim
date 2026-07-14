local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local INTERVAL_MS = 80

M.timer = nil
M.win = nil
M.buf = nil

--- 画面右下に「AI 解析中」を示すフローティングウィンドウを開き、スピナーを回し始める
function M.start(label)
  M.stop()

  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].buftype = "nofile"
  vim.bo[M.buf].bufhidden = "wipe"

  local text = FRAMES[1] .. " " .. label
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, { text })

  M.win = vim.api.nvim_open_win(M.buf, false, {
    relative = "editor",
    anchor = "SE",
    row = vim.o.lines - vim.o.cmdheight,
    col = vim.o.columns,
    width = vim.fn.strdisplaywidth(text),
    height = 1,
    style = "minimal",
    focusable = false,
    zindex = 300,
    border = "none",
  })

  local frame = 1
  M.timer = vim.uv.new_timer()
  M.timer:start(
    0,
    INTERVAL_MS,
    vim.schedule_wrap(function()
      if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
        M.stop()
        return
      end
      frame = (frame % #FRAMES) + 1
      vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, { FRAMES[frame] .. " " .. label })
    end)
  )
end

--- タイマー停止 + ウィンドウ/バッファを閉じる。多重呼び出しや閉じた後の呼び出しも安全。
function M.stop()
  if M.timer then
    M.timer:stop()
    M.timer:close()
    M.timer = nil
  end
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win = nil
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    vim.api.nvim_buf_delete(M.buf, { force = true })
  end
  M.buf = nil
end

return M
