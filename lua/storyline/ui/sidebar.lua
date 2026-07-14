local config = require("storyline.config")
local story = require("storyline.story")
local layout = require("storyline.ui.layout")

local M = {
  buf = nil,
  entries = {}, -- 行番号(1-index) → { type = "chapter"|"file", ... }
}

local ns = vim.api.nvim_create_namespace("storyline_sidebar")

vim.api.nvim_set_hl(0, "StorylineTitle", { default = true, link = "Title" })
vim.api.nvim_set_hl(0, "StorylineChapter", { default = true, link = "Function" })
vim.api.nvim_set_hl(0, "StorylineChapterCurrent", { default = true, link = "Title" })
vim.api.nvim_set_hl(0, "StorylineChapterRead", { default = true, link = "Comment" })
vim.api.nvim_set_hl(0, "StorylineStat", { default = true, link = "Comment" })
vim.api.nvim_set_hl(0, "StorylineDeleted", { default = true, link = "DiffDelete" })

--- チャプター内ファイルの共通ディレクトリプレフィックスを求める（テスト可能な純関数）
--- 1ファイルだけの場合もその親ディレクトリまで畳む
function M.common_dir_prefix(paths)
  if #paths == 0 then
    return ""
  end
  local dirs = {}
  for i, p in ipairs(paths) do
    dirs[i] = vim.split(p, "/", { plain = true })
    table.remove(dirs[i]) -- ファイル名は含めない
  end
  local prefix = {}
  local idx = 1
  while true do
    local seg = dirs[1][idx]
    if seg == nil then
      break
    end
    for _, d in ipairs(dirs) do
      if d[idx] ~= seg then
        return table.concat(prefix, "/")
      end
    end
    table.insert(prefix, seg)
    idx = idx + 1
  end
  return table.concat(prefix, "/")
end

--- 表示幅に収まるようパスを短縮する。まず pathshorten（a/b/file.ts）、
--- それでも長ければファイル名優先で先頭を「…」に切り詰める
function M.shorten_path(path, max_width)
  if max_width <= 0 or vim.fn.strdisplaywidth(path) <= max_width then
    return path
  end
  local short = vim.fn.pathshorten(path)
  if vim.fn.strdisplaywidth(short) <= max_width then
    return short
  end
  return "…" .. vim.fn.strcharpart(short, vim.fn.strchars(short) - (max_width - 1))
end

--- カーソル行の entry（file 行なら所属チャプターも返す）
local function entry_at_cursor()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return M.entries[line]
end

local function chapter_at_cursor()
  local entry = entry_at_cursor()
  if not entry then
    return nil
  end
  if entry.type == "chapter" then
    return story.chapter(entry.id)
  end
  return story.chapter(entry.chapter_id)
end

local function jump_chapter(direction)
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local total = vim.api.nvim_buf_line_count(M.buf)
  local line = cur + direction
  while line >= 1 and line <= total do
    local entry = M.entries[line]
    if entry and entry.type == "chapter" then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      return
    end
    line = line + direction
  end
end

local function set_collapsed(value)
  local s = story.current
  local ch = chapter_at_cursor()
  if not s or not ch then
    return
  end
  s.collapsed[ch.id] = value or nil
  M.render()
  -- 折り畳んだときはチャプター行へカーソルを戻す
  for line, entry in pairs(M.entries) do
    if entry.type == "chapter" and entry.id == ch.id then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      break
    end
  end
end

local function on_select()
  local s = story.current
  local entry = entry_at_cursor()
  if not s or not entry then
    return
  end
  if entry.type == "chapter" then
    story.set_current_chapter(entry.id)
    M.render()
    require("storyline.ui.summary").show(story.chapter(entry.id))
  else
    require("storyline.ui.main").open_file(s.files_by_path[entry.path])
  end
end

--- <CR> と違い、ファイルを開いてもフォーカスをサイドバーに残す。
--- フォーカス復帰は gitsigns の非同期レイアウト適用が終わってから main 側が行う。
local function on_preview()
  local s = story.current
  local entry = entry_at_cursor()
  if not s or not entry then
    return
  end
  if entry.type == "file" then
    require("storyline.ui.main").open_file(s.files_by_path[entry.path], { keep_focus = "sidebar" })
  else
    on_select()
  end
end

local function setup_keymaps(buf)
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, desc = "Storyline: " .. desc })
  end
  map("<CR>", on_select, "チャプター概要 / ファイルを開く")
  map("p", on_preview, "フォーカスを残したままファイルを開く")
  map("h", function()
    set_collapsed(true)
  end, "チャプターを折り畳む")
  map("l", function()
    set_collapsed(false)
  end, "チャプターを展開する")
  map("o", function()
    local ch = chapter_at_cursor()
    if ch then
      require("storyline.ui.summary").show(ch)
    end
  end, "チャプター概要を表示")
  map("v", function()
    local ch = chapter_at_cursor()
    if ch then
      require("storyline.ui.main").open_chapter_in_diffview(ch)
    end
  end, "チャプターを Diffview で開く")
  map("m", function()
    local ch = chapter_at_cursor()
    if ch then
      story.toggle_read(ch.id)
      M.render()
    end
  end, "読了マークをトグル")
  map("]c", function()
    jump_chapter(1)
  end, "次のチャプターへ")
  map("[c", function()
    jump_chapter(-1)
  end, "前のチャプターへ")
  map("R", function()
    require("storyline").refresh()
  end, "AI 解析をやり直す")
  map("q", function()
    require("storyline").close()
  end, "終了")
end

function M.attach(win)
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].buftype = "nofile"
  vim.bo[M.buf].bufhidden = "wipe"
  vim.bo[M.buf].swapfile = false
  vim.bo[M.buf].filetype = "storyline"
  vim.api.nvim_buf_set_name(M.buf, "storyline://sidebar")
  vim.api.nvim_win_set_buf(win, M.buf)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true
  -- サイドバーのウィンドウで別バッファが開かれる事故を構造的に防ぐ
  pcall(function()
    vim.wo[win].winfixbuf = true
  end)
  setup_keymaps(M.buf)
end

function M.render()
  local s = story.current
  if not s or not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end

  local lines, marks = {}, {}
  M.entries = {}

  local function add(text, entry, hl)
    table.insert(lines, text)
    if entry then
      M.entries[#lines] = entry
    end
    if hl then
      table.insert(marks, { line = #lines - 1, hl = hl })
    end
  end

  add(s.title ~= "" and s.title or "Storyline", nil, "StorylineTitle")
  add(("base: %s"):format(s.base_ref), nil, "StorylineStat")
  add("")

  for _, ch in ipairs(s.chapters) do
    local icon = s.read[ch.id] and "✓" or (s.current_chapter == ch.id and "▸" or "·")
    local hl = s.read[ch.id] and "StorylineChapterRead"
      or (s.current_chapter == ch.id and "StorylineChapterCurrent" or "StorylineChapter")
    add(("%s %d. %s"):format(icon, ch.id, ch.title), { type = "chapter", id = ch.id }, hl)

    if not s.collapsed[ch.id] then
      local width = config.options.sidebar_width
      local dir_prefix = config.options.shorten_paths and M.common_dir_prefix(ch.files) or ""
      if dir_prefix ~= "" then
        add(
          "   " .. M.shorten_path(dir_prefix, width - 5) .. "/",
          { type = "chapter", id = ch.id },
          "StorylineStat"
        )
      end
      for _, path in ipairs(ch.files) do
        local f = s.files_by_path[path]
        local opened = s.opened[path] and "•" or " "
        local suffix = f and (" +%d -%d"):format(f.added, f.deleted) or ""
        local prefix = "  "
        if f and f.status == "D" then
          prefix = "D "
        elseif f and f.status == "R" then
          prefix = "R "
        end
        local rel = dir_prefix ~= "" and path:sub(#dir_prefix + 2) or path
        if config.options.shorten_paths then
          rel = M.shorten_path(rel, width - 4 - vim.fn.strdisplaywidth(suffix))
        end
        add(
          (" %s%s%s%s"):format(opened, prefix, rel, suffix),
          { type = "file", path = path, chapter_id = ch.id },
          (f and f.status == "D") and "StorylineDeleted" or nil
        )
      end
    end
    add("")
  end

  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(M.buf, ns, mark.line, 0, {
      end_row = mark.line + 1,
      hl_group = mark.hl,
      hl_eol = true,
    })
  end
end

return M
