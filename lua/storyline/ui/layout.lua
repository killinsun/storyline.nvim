local config = require("storyline.config")

local M = {}

M.tab = nil
M.sidebar_win = nil
M.main_win = nil

local augroup = vim.api.nvim_create_augroup("storyline_layout", { clear = false })

function M.is_open()
  return M.tab ~= nil and vim.api.nvim_tabpage_is_valid(M.tab)
end

--- 専用タブページ + 左サイドバーを作る
function M.open()
  vim.cmd("tabnew")
  M.tab = vim.api.nvim_get_current_tabpage()
  M.main_win = vim.api.nvim_get_current_win()

  vim.cmd("topleft " .. config.options.sidebar_width .. "vsplit")
  M.sidebar_win = vim.api.nvim_get_current_win()
  vim.wo[M.sidebar_win].winfixwidth = true

  -- ユーザーが :q などでタブを閉じた場合も gitsigns 設定を復元する
  vim.api.nvim_clear_autocmds({ group = augroup })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function()
      vim.schedule(function()
        if not M.is_open() then
          M.cleanup()
        end
      end)
    end,
  })
end

function M.focus_sidebar()
  if M.sidebar_win and vim.api.nvim_win_is_valid(M.sidebar_win) then
    vim.api.nvim_set_current_win(M.sidebar_win)
  end
end

--- メインウィンドウを返す。閉じられていたら（gd ジャンプ後の :q など）作り直す
function M.ensure_main()
  if M.main_win and vim.api.nvim_win_is_valid(M.main_win) then
    return M.main_win
  end
  if not M.is_open() then
    return nil
  end
  local anchor = (M.sidebar_win and vim.api.nvim_win_is_valid(M.sidebar_win)) and M.sidebar_win
    or vim.api.nvim_tabpage_list_wins(M.tab)[1]
  vim.api.nvim_set_current_win(anchor)
  vim.cmd("botright vsplit")
  M.main_win = vim.api.nvim_get_current_win()
  return M.main_win
end

function M.focus_main()
  local win = M.ensure_main()
  if win then
    vim.api.nvim_set_current_win(win)
  end
end

--- 状態の後始末（タブは残っていても呼べる）
function M.cleanup()
  require("storyline.ui.main").teardown()
  require("storyline.story").clear()
  vim.api.nvim_clear_autocmds({ group = augroup })
  M.tab, M.sidebar_win, M.main_win = nil, nil, nil
end

function M.close()
  if M.is_open() then
    local tab = M.tab
    M.cleanup()
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose")
  else
    M.cleanup()
  end
end

return M
