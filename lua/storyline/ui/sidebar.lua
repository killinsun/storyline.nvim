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
vim.api.nvim_set_hl(0, "StorylineDir", { default = true, link = "Directory" })
vim.api.nvim_set_hl(0, "StorylineAdded", { default = true, link = "Added" })
vim.api.nvim_set_hl(0, "StorylineRemoved", { default = true, link = "Removed" })
vim.api.nvim_set_hl(0, "StorylineRenamed", { default = true, link = "Changed" })

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

--- パス一覧をディレクトリツリーに変換する（テスト可能な純関数）。
--- GitHub の PR ツリーと同様、「ファイルを持たず子ディレクトリが1つだけ」の
--- 連鎖は "a/b/c" のように1ノードへ連結する。
--- 返り値ノード: { name?, dirs = {ノード...}, files = { {name, path} } }（dirs/files とも名前順）
function M.build_tree(paths)
  local function new_node()
    return { dirs = {}, files = {} }
  end
  local root = new_node()
  for _, path in ipairs(paths) do
    local parts = vim.split(path, "/", { plain = true })
    local node = root
    for i = 1, #parts - 1 do
      local seg = parts[i]
      if not node.dirs[seg] then
        node.dirs[seg] = new_node()
      end
      node = node.dirs[seg]
    end
    table.insert(node.files, { name = parts[#parts], path = path })
  end

  local function normalize(node)
    local dirs = {}
    for name, child in pairs(node.dirs) do
      local merged_name, cur = name, child
      while true do
        local count, only_name, only_child = 0, nil, nil
        for n, c in pairs(cur.dirs) do
          count = count + 1
          only_name, only_child = n, c
        end
        if #cur.files == 0 and count == 1 then
          merged_name = merged_name .. "/" .. only_name
          cur = only_child
        else
          break
        end
      end
      local norm = normalize(cur)
      norm.name = merged_name
      table.insert(dirs, norm)
    end
    table.sort(dirs, function(a, b)
      return a.name < b.name
    end)
    table.sort(node.files, function(a, b)
      return a.name < b.name
    end)
    return { dirs = dirs, files = node.files }
  end
  return normalize(root)
end

--- ディレクトリ名の短縮: 末尾のディレクトリを優先して「…/b/c」形式にする
--- （ファイルパスと違い、ディレクトリは末尾ほど情報量が多いため）
function M.shorten_dir(name, max_width)
  if vim.fn.strdisplaywidth(name) <= max_width then
    return name
  end
  local parts = vim.split(name, "/", { plain = true })
  local acc = parts[#parts]
  for i = #parts - 1, 1, -1 do
    local candidate = parts[i] .. "/" .. acc
    if vim.fn.strdisplaywidth("…/" .. candidate) > max_width then
      break
    end
    acc = candidate
  end
  return "…/" .. acc
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
  map(config.options.keymaps.preview, on_preview, "フォーカスを残したままファイルを開く")
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

local STATUS_HL = { A = "StorylineAdded", D = "StorylineRemoved", R = "StorylineRenamed" }

function M.render()
  local s = story.current
  if not s or not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end

  local has_devicons, devicons = pcall(require, "nvim-web-devicons")
  local width = config.options.sidebar_width
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

  --- ファイル行: 開封マーク + アイコン + 名前（ステータス色）+ 色付き +N -M
  local function add_file_line(f, display_name, indent, chapter_id)
    local opened = s.opened[f.path] and "•" or " "
    local icon, icon_hl = "", nil
    if has_devicons then
      local i, hl = devicons.get_icon(f.path:match("[^/]+$") or f.path, nil, { default = true })
      if i then
        icon, icon_hl = i .. " ", hl
      end
    end
    local plus = " +" .. f.added
    local minus = " -" .. f.deleted
    local fixed = " " .. opened .. indent .. icon
    local avail = width - vim.fn.strdisplaywidth(fixed .. plus .. minus)
    if avail > 1 and vim.fn.strdisplaywidth(display_name) > avail then
      display_name = vim.fn.strcharpart(display_name, 0, avail - 1) .. "…"
    end
    add(fixed .. display_name .. plus .. minus, { type = "file", path = f.path, chapter_id = chapter_id })

    local row = #lines - 1
    if icon_hl and icon ~= "" then
      local icon_s = #(" " .. opened .. indent)
      table.insert(marks, { line = row, hl = icon_hl, col_s = icon_s, col_e = icon_s + #icon })
    end
    local name_s = #fixed
    local name_e = name_s + #display_name
    if STATUS_HL[f.status] then
      table.insert(marks, { line = row, hl = STATUS_HL[f.status], col_s = name_s, col_e = name_e })
    end
    table.insert(marks, { line = row, hl = "StorylineAdded", col_s = name_e, col_e = name_e + #plus })
    table.insert(marks, { line = row, hl = "StorylineRemoved", col_s = name_e + #plus, col_e = name_e + #plus + #minus })
  end

  --- GitHub の PR ツリー風: ディレクトリ階層 + ファイル名のみ
  local function add_tree(node, depth, chapter_id)
    for _, dir in ipairs(node.dirs) do
      local indent = "   " .. string.rep("  ", depth)
      local name = M.shorten_dir(dir.name, width - vim.fn.strdisplaywidth(indent) - 1)
      add(indent .. name .. "/", { type = "chapter", id = chapter_id }, "StorylineDir")
      add_tree(dir, depth + 1, chapter_id)
    end
    for _, file in ipairs(node.files) do
      local f = s.files_by_path[file.path]
      if f then
        add_file_line(f, file.name, " " .. string.rep("  ", depth), chapter_id)
      end
    end
  end

  --- flat: 共通ディレクトリを1行に畳んで相対パスを一覧
  local function add_flat(ch)
    local dir_prefix = config.options.shorten_paths and M.common_dir_prefix(ch.files) or ""
    if dir_prefix ~= "" then
      add("   " .. M.shorten_dir(dir_prefix, width - 5) .. "/", { type = "chapter", id = ch.id }, "StorylineDir")
    end
    for _, path in ipairs(ch.files) do
      local f = s.files_by_path[path]
      if f then
        local rel = dir_prefix ~= "" and path:sub(#dir_prefix + 2) or path
        add_file_line(f, rel, "  ", ch.id)
      end
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
      if config.options.sidebar_style == "tree" then
        add_tree(M.build_tree(ch.files), 0, ch.id)
      else
        add_flat(ch)
      end
    end
    add("")
  end

  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    if mark.col_s then
      vim.api.nvim_buf_set_extmark(M.buf, ns, mark.line, mark.col_s, {
        end_col = mark.col_e,
        hl_group = mark.hl,
      })
    else
      vim.api.nvim_buf_set_extmark(M.buf, ns, mark.line, 0, {
        end_row = mark.line + 1,
        hl_group = mark.hl,
        hl_eol = true,
      })
    end
  end
end

return M
