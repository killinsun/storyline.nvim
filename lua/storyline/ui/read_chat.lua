--- StorylineRead 用の対話フロート（履歴 + 入力）
local M = {
  chat_win = nil,
  input_win = nil,
  chat_buf = nil,
  input_buf = nil,
  messages = {},
  topic = nil,
  on_submit = nil,
  on_cancel = nil,
  closed = true,
}

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function render()
  if not valid_buf(M.chat_buf) then
    return
  end

  local lines = {}
  if M.topic and M.topic ~= "" then
    table.insert(lines, "# " .. M.topic)
    table.insert(lines, "")
  end

  for _, msg in ipairs(M.messages) do
    local prefix = msg.role == "user" and "You: " or "Storyline: "
    local body = vim.split(msg.text or "", "\n", { plain = true })
    for i, line in ipairs(body) do
      if i == 1 then
        table.insert(lines, prefix .. line)
      else
        table.insert(lines, "  " .. line)
      end
    end
    table.insert(lines, "")
  end

  if #lines == 0 then
    lines = { "" }
  end

  vim.bo[M.chat_buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.chat_buf, 0, -1, false, lines)
  vim.bo[M.chat_buf].modifiable = false

  if valid_win(M.chat_win) then
    pcall(vim.api.nvim_win_set_cursor, M.chat_win, { #lines, 0 })
  end
end

function M.close()
  if M.closed then
    return
  end
  M.closed = true
  pcall(vim.cmd, "stopinsert")

  if valid_win(M.input_win) then
    pcall(vim.api.nvim_win_close, M.input_win, true)
  end
  if valid_win(M.chat_win) then
    pcall(vim.api.nvim_win_close, M.chat_win, true)
  end
  M.chat_win = nil
  M.input_win = nil
  M.chat_buf = nil
  M.input_buf = nil
  M.messages = {}
  M.topic = nil
  M.on_submit = nil
  M.on_cancel = nil
end

function M.append(role, text)
  if M.closed then
    return
  end
  table.insert(M.messages, { role = role, text = text })
  render()
end

local function submit_input()
  if M.closed or not valid_buf(M.input_buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
  local text = vim.trim(table.concat(lines, " "))
  vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "" })
  if M.on_submit then
    M.on_submit(text)
  end
end

local function cancel()
  local cb = M.on_cancel
  M.close()
  if cb then
    cb()
  end
end

--- opts: { topic, on_submit(text), on_cancel? }
function M.open(opts)
  opts = opts or {}
  M.close()
  M.closed = false
  M.messages = {}
  M.topic = opts.topic
  M.on_submit = opts.on_submit
  M.on_cancel = opts.on_cancel

  M.chat_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.chat_buf].buftype = "nofile"
  vim.bo[M.chat_buf].bufhidden = "wipe"
  vim.bo[M.chat_buf].modifiable = false
  vim.bo[M.chat_buf].filetype = "markdown"

  M.input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.input_buf].buftype = "nofile"
  vim.bo[M.input_buf].bufhidden = "wipe"
  vim.bo[M.input_buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "" })

  local width = math.min(72, math.max(48, math.floor(vim.o.columns * 0.55)))
  local chat_height = math.min(18, math.max(8, math.floor(vim.o.lines * 0.35)))
  local input_height = 1
  local gap = 1
  local total_h = chat_height + input_height + gap + 4 -- borders approx
  local row = math.max(1, math.floor((vim.o.lines - total_h) / 2))
  local col = math.floor((vim.o.columns - width) / 2)

  M.chat_win = vim.api.nvim_open_win(M.chat_buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = chat_height,
    style = "minimal",
    border = "rounded",
    title = " Storyline 読む ",
    title_pos = "center",
    zindex = 200,
  })
  vim.wo[M.chat_win].wrap = true
  vim.wo[M.chat_win].linebreak = true
  vim.wo[M.chat_win].cursorline = false

  M.input_win = vim.api.nvim_open_win(M.input_buf, true, {
    relative = "editor",
    row = row + chat_height + gap + 2,
    col = col,
    width = width,
    height = input_height,
    style = "minimal",
    border = "rounded",
    title = " 空 Enter で確定 / q キャンセル ",
    title_pos = "left",
    zindex = 201,
  })

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, cancel, {
      buffer = M.chat_buf,
      nowait = true,
      desc = "Storyline: 対話をキャンセル",
    })
    vim.keymap.set("n", key, cancel, {
      buffer = M.input_buf,
      nowait = true,
      desc = "Storyline: 対話をキャンセル",
    })
  end

  vim.keymap.set({ "i", "n" }, "<CR>", function()
    submit_input()
  end, { buffer = M.input_buf, nowait = true, desc = "Storyline: 送信 / 確定" })

  vim.keymap.set("i", "<C-c>", function()
    vim.cmd("stopinsert")
    cancel()
  end, { buffer = M.input_buf, nowait = true, desc = "Storyline: 対話をキャンセル" })

  render()
  vim.cmd("startinsert")
end

return M
