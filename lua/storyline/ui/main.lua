local config = require("storyline.config")
local git = require("storyline.git")
local story = require("storyline.story")
local layout = require("storyline.ui.layout")

local M = {
  layout_mode = nil, -- "unified" | "split"
  saved = nil, -- gitsigns のグローバル表示設定の退避先
  mapped_bufs = {},
  current = nil, -- 表示中の file entry
}

local augroup = vim.api.nvim_create_augroup("storyline_main", { clear = false })

local function gs()
  local ok, mod = pcall(require, "gitsigns")
  return ok and mod or nil
end

local function set_unified_toggles(g, on)
  pcall(g.toggle_deleted, on)
  pcall(g.toggle_linehl, on)
  pcall(g.toggle_word_diff, on)
end

function M.setup_session()
  M.layout_mode = config.options.layout
  M.current = nil
  M.mapped_bufs = {}

  local ok, gs_config = pcall(function()
    return require("gitsigns.config").config
  end)
  if ok then
    M.saved = {
      show_deleted = gs_config.show_deleted,
      linehl = gs_config.linehl,
      word_diff = gs_config.word_diff,
    }
  end

  -- gitsigns のアタッチは非同期なので、アタッチ完了後に base を merge-base へ切り替える
  vim.api.nvim_clear_autocmds({ group = augroup })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "GitSignsAttach",
    callback = function(args)
      local s = story.current
      if not s or M.layout_mode ~= "unified" then
        return
      end
      local buf = args.data and args.data.buffer or args.buf
      local g = gs()
      if g and buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_call(buf, function()
          pcall(g.change_base, s.merge_base)
        end)
      end
    end,
  })
end

function M.teardown()
  local g = gs()
  if g and M.saved then
    set_unified_toggles(g, false)
    pcall(g.toggle_deleted, M.saved.show_deleted)
    pcall(g.toggle_linehl, M.saved.linehl)
    pcall(g.toggle_word_diff, M.saved.word_diff)
  end
  for buf in pairs(M.mapped_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.keymap.del, "n", config.options.keymaps.toggle_layout, { buffer = buf })
      if g then
        vim.api.nvim_buf_call(buf, function()
          pcall(g.change_base, nil)
        end)
      end
    end
  end
  vim.api.nvim_clear_autocmds({ group = augroup })
  M.mapped_bufs = {}
  M.saved = nil
  M.current = nil
end

--- split 表示で開いた gitsigns:// の diff ウィンドウを閉じ、diff mode を解除
local function clear_diff()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:match("^gitsigns://") then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if layout.main_win and vim.api.nvim_win_is_valid(layout.main_win) then
    vim.api.nvim_win_call(layout.main_win, function()
      vim.cmd("diffoff")
    end)
  end
end

local function apply_layout()
  local g = gs()
  local s = story.current
  if not g or not s then
    return
  end
  if M.layout_mode == "split" then
    set_unified_toggles(g, false)
    pcall(g.diffthis, s.merge_base, { vertical = true })
  else
    pcall(g.change_base, s.merge_base)
    set_unified_toggles(g, true)
  end
end

local function attach_keymaps(buf)
  if M.mapped_bufs[buf] then
    return
  end
  M.mapped_bufs[buf] = true
  vim.keymap.set("n", config.options.keymaps.toggle_layout, function()
    M.toggle_layout()
  end, { buffer = buf, desc = "Storyline: unified/split 切替" })
end

--- 削除ファイルは base 時点の内容を読み取り専用 scratch で表示（LSP 対象外と割り切る）
local function open_deleted(entry, merge_base)
  local name = "storyline://deleted/" .. entry.path
  local buf = vim.fn.bufnr(name)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, git.show_base_file(merge_base, entry.path) or {})
    vim.bo[buf].modifiable = false
    vim.bo[buf].buftype = "nofile"
    local ft = vim.filetype.match({ filename = entry.path })
    if ft then
      vim.bo[buf].filetype = ft
    end
  end
  vim.api.nvim_win_set_buf(0, buf)
end

function M.open_file(entry)
  local s = story.current
  if not s then
    return
  end
  layout.focus_main()
  clear_diff()

  if entry.status == "D" then
    open_deleted(entry, s.merge_base)
  else
    vim.cmd.edit(vim.fn.fnameescape(s.repo_root .. "/" .. entry.path))
    apply_layout()
  end

  M.current = entry
  attach_keymaps(vim.api.nvim_get_current_buf())

  if story.mark_opened(entry.path, config.options.auto_read_mark) then
    require("storyline.ui.sidebar").render()
  end
end

function M.toggle_layout()
  M.layout_mode = M.layout_mode == "split" and "unified" or "split"
  if M.current and M.current.status ~= "D" then
    layout.focus_main()
    clear_diff()
    apply_layout()
  end
  vim.notify("Storyline: " .. (M.layout_mode == "split" and "split 表示" or "unified 表示"), vim.log.levels.INFO)
end

--- diffview.nvim がインストールされていればチャプターの対象ファイルを DiffviewOpen で開く
--- （未インストール時はエスケープハッチとして警告のみで終了）
function M.open_chapter_in_diffview(chapter)
  local ok = pcall(require, "diffview")
  if not ok then
    vim.notify("Storyline: diffview.nvim が見つかりません", vim.log.levels.WARN)
    return
  end

  local s = story.current
  if not s or not chapter then
    return
  end

  local paths = {}
  for _, path in ipairs(chapter.files) do
    table.insert(paths, vim.fn.fnameescape(s.repo_root .. "/" .. path))
  end

  vim.cmd("DiffviewOpen " .. s.merge_base .. " -- " .. table.concat(paths, " "))
end

return M
