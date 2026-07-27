local config = require("storyline.config")
local git = require("storyline.git")
local story = require("storyline.story")
local layout = require("storyline.ui.layout")

local M = {
  layout_mode = nil, -- "unified" | "split"
  saved = nil, -- gitsigns のグローバル表示設定の退避先
  mapped_bufs = {},
  current = nil, -- 表示中の file entry
  busy = false, -- gitsigns の非同期レイアウト適用中
  queued = nil, -- busy 中に来た open_file 要求（最新のみ保持）
  auto_split_notified = {}, -- 自動 split 通知済みパス（同一ファイルの連続通知を抑止）
}

local augroup = vim.api.nvim_create_augroup("storyline_main", { clear = false })

local function gs()
  local ok, mod = pcall(require, "gitsigns")
  return ok and mod or nil
end

local function set_unified_toggles(g, on)
  pcall(g.toggle_deleted, on)
  pcall(g.toggle_linehl, on)
  pcall(g.toggle_word_diff, on and config.options.unified.word_diff)
end

--- 変更行数が threshold 以上なら split 表示へ自動切替するか
function M.should_auto_split(entry, threshold)
  if not threshold or threshold <= 0 then
    return false
  end
  if not entry or entry.status == "D" then
    return false
  end
  return (entry.added or 0) + (entry.deleted or 0) >= threshold
end

local function is_read_mode()
  local s = story.current
  return s and s.mode == "read"
end

function M.setup_session()
  M.layout_mode = config.options.layout
  M.current = nil
  M.mapped_bufs = {}
  M.busy = false
  M.queued = nil
  M.auto_split_notified = {}

  -- 読むモードは diff を使わない
  if is_read_mode() then
    M.saved = nil
    vim.api.nvim_clear_autocmds({ group = augroup })
    return
  end

  local ok, gs_config = pcall(function()
    return require("gitsigns.config").config
  end)
  if ok then
    M.saved = {
      show_deleted = gs_config.show_deleted,
      linehl = gs_config.linehl,
      word_diff = gs_config.word_diff,
      diff_opts = vim.deepcopy(gs_config.diff_opts or {}),
    }
    gs_config.diff_opts = vim.tbl_deep_extend(
      "force",
      vim.deepcopy(gs_config.diff_opts or {}),
      config.options.unified.diff_opts
    )
  end

  -- gd ジャンプなどで open_file を経由せず開かれたバッファにも merge-base 基準を適用する。
  -- GitSignsUpdate は更新のたびに発火するので、base が既に一致していれば何もしない（ループ防止）。
  vim.api.nvim_clear_autocmds({ group = augroup })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "GitSignsUpdate",
    callback = function(args)
      local s = story.current
      if not s or s.mode == "read" or M.layout_mode ~= "unified" or not layout.is_open() then
        return
      end
      local buf = args.data and args.data.buffer
      local g = gs()
      if not g or not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local ok, gs_cache = pcall(require, "gitsigns.cache")
      local bcache = ok and gs_cache.cache[buf] or nil
      if not bcache or bcache.base == s.merge_base then
        return
      end
      -- storyline タブに表示されているバッファだけを対象にする
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(layout.tab)) do
        if vim.api.nvim_win_get_buf(win) == buf then
          vim.api.nvim_buf_call(buf, function()
            pcall(g.change_base, s.merge_base)
          end)
          return
        end
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
    local ok, gs_config = pcall(function()
      return require("gitsigns.config").config
    end)
    if ok and M.saved.diff_opts then
      gs_config.diff_opts = M.saved.diff_opts
    end
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
  M.busy = false
  M.queued = nil
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

--- レイアウトを適用し、gitsigns の非同期処理が終わってから cb を呼ぶ。
--- diffthis / change_base は非同期で「実行時点のカレントバッファ」を対象にするため、
--- 完了までフォーカスを動かしてはいけない（動かすとサイドバーが対象になる）。
local function apply_layout(cb)
  local called = false
  local finish = vim.schedule_wrap(function()
    if called then
      return
    end
    called = true
    if cb then
      cb()
    end
  end)

  local g = gs()
  local s = story.current
  if not g or not s then
    finish()
    return
  end

  -- gitsigns のアタッチも非同期なので、未アタッチのうちに diffthis すると空振りする。
  -- アタッチ完了をポーリングで待ってから適用する（gitsigns はアタッチ完了の
  -- User autocmd を発火しないため、キャッシュを直接見るしかない）。
  local buf = vim.api.nvim_get_current_buf()
  local function apply()
    if vim.api.nvim_get_current_buf() ~= buf then
      -- 待っている間に表示が変わった（連打などで次の open が始まった）
      finish()
      return
    end
    local ok
    if M.layout_mode == "split" then
      set_unified_toggles(g, false)
      -- unified で change_base(merge_base) 済みのバッファに diffthis(merge_base) すると
      -- gitsigns 内部の assertion（base == revision なのに compare_text 未計算）を踏む。
      -- base をリセットしてから diffthis する。
      ok = pcall(
        g.change_base,
        nil,
        false,
        vim.schedule_wrap(function()
          local diff_ok = pcall(g.diffthis, s.merge_base, { vertical = true }, finish)
          if not diff_ok then
            finish()
          end
        end)
      )
    else
      ok = pcall(g.change_base, s.merge_base, false, finish)
      set_unified_toggles(g, true)
    end
    if not ok then
      finish()
    end
  end

  local cache_ok, gs_cache = pcall(require, "gitsigns.cache")
  if not cache_ok then
    finish()
    return
  end
  if gs_cache.cache[buf] then
    apply()
  else
    local tries = 0
    local timer = vim.uv.new_timer()
    timer:start(
      50,
      50,
      vim.schedule_wrap(function()
        tries = tries + 1
        if gs_cache.cache[buf] or tries > 40 then
          timer:stop()
          timer:close()
          if gs_cache.cache[buf] then
            apply()
          else
            finish() -- git 管理外などアタッチされないバッファ
          end
        end
      end)
    )
  end
  -- gitsigns がコールバックを呼ばないケースの最終保険（busy が固着しないように）
  vim.defer_fn(finish, 4000)
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

--- opts:
---   keep_focus = "sidebar": レイアウト適用完了後にフォーカスをサイドバーへ戻す
---   on_done = function: レイアウト適用完了後に呼ぶ
--- 適用完了前に次の open_file が来たらキューに積んで直列化する（p 連打対策）。
function M.open_file(entry, opts)
  opts = opts or {}
  local s = story.current
  if not s then
    return
  end
  if M.busy then
    M.queued = { entry = entry, opts = opts }
    return
  end
  M.busy = true

  layout.focus_main()
  clear_diff()

  local function finish()
    M.busy = false
    -- ユーザーが既に別ウィンドウへ移っていたらフォーカスを奪わない
    if opts.keep_focus == "sidebar" and vim.api.nvim_get_current_win() == layout.main_win then
      layout.focus_sidebar()
    end
    if opts.on_done then
      pcall(opts.on_done)
    end
    if story.mark_opened(entry.path, config.options.auto_read_mark) then
      require("storyline.ui.sidebar").render()
    end
    local q = M.queued
    M.queued = nil
    if q then
      M.open_file(q.entry, q.opts)
    end
  end

  M.current = entry

  if entry.status == "D" then
    open_deleted(entry, s.merge_base)
    attach_keymaps(vim.api.nvim_get_current_buf())
    finish()
  else
    -- 読むモード: ソースをそのまま開く（diff / gitsigns なし）
    if s.mode == "read" then
      vim.cmd.edit(vim.fn.fnameescape(s.repo_root .. "/" .. entry.path))
      attach_keymaps(vim.api.nvim_get_current_buf())
      finish()
      return
    end
    if M.should_auto_split(entry, config.options.auto_split_lines) then
      if M.layout_mode ~= "split" then
        M.layout_mode = "split"
        if not M.auto_split_notified[entry.path] then
          M.auto_split_notified[entry.path] = true
          vim.notify("Storyline: 変更が大きいため split 表示に切り替えました", vim.log.levels.INFO)
        end
      end
    end
    vim.cmd.edit(vim.fn.fnameescape(s.repo_root .. "/" .. entry.path))
    attach_keymaps(vim.api.nvim_get_current_buf())
    apply_layout(finish)
  end
end

function M.toggle_layout()
  if is_read_mode() then
    vim.notify("Storyline: 読むモードでは diff レイアウト切替はありません", vim.log.levels.INFO)
    return
  end
  if M.busy then
    return
  end
  M.layout_mode = M.layout_mode == "split" and "unified" or "split"
  if M.current and M.current.status ~= "D" then
    M.busy = true
    layout.focus_main()
    clear_diff()
    apply_layout(function()
      M.busy = false
    end)
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
